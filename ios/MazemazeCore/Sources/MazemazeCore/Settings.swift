import Foundation

public protocol SecretStore: Sendable {
    func token() -> String?
    func setToken(_ token: String?) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(token: String? = nil) { value = token }
    public func token() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    public func setToken(_ token: String?) throws { lock.lock(); defer { lock.unlock() }; value = token }
}

public struct ServerConfig: Equatable, Sendable {
    public var baseURL: URL
    public var token: String?
    public init(baseURL: URL, token: String?) { self.baseURL = baseURL; self.token = token }
}

/// Non-secret preferences live in UserDefaults; the token lives only in the SecretStore (Keychain).
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let secrets: SecretStore
    enum Key {
        static let serverURL = "mazemaze.serverURL"
        static let ratio = "mazemaze.ratio"
        static let unit = "mazemaze.unit"
        static let enabled = "mazemaze.enabled"
        static let hosts = "mazemaze.allowedHosts"
    }

    public init(defaults: UserDefaults = .standard, secrets: SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public var serverURLString: String {
        get { defaults.string(forKey: Key.serverURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.serverURL) }
    }
    public var token: String? { secrets.token() }
    public func setToken(_ t: String?) throws {
        let trimmed = t?.trimmingCharacters(in: .whitespacesAndNewlines)
        try secrets.setToken((trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    public var ratio: Double {
        get { let v = defaults.double(forKey: Key.ratio); return v == 0 ? 0.3 : min(max(v, 0.1), 0.7) }
        set { defaults.set(min(max(newValue, 0.1), 0.7), forKey: Key.ratio) }
    }
    public var unit: TranslationUnit {
        get { TranslationUnit(rawValue: defaults.string(forKey: Key.unit) ?? "") ?? .phrase }
        set { defaults.set(newValue.rawValue, forKey: Key.unit) }
    }
    public var translationEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    public var allowedHosts: [String] {
        get { (defaults.array(forKey: Key.hosts) as? [String]).map { $0.compactMap(SitePolicy.normalizeEntry) } ?? SitePolicy.defaultAllowedHosts }
        set { defaults.set(newValue.compactMap(SitePolicy.normalizeEntry), forKey: Key.hosts) }
    }

    /// The validated server configuration, or nil if the URL is missing or not a local address.
    public func serverConfig() -> ServerConfig? {
        guard case .success(let url) = LocalHostPolicy.validate(serverURLString) else { return nil }
        return ServerConfig(baseURL: url, token: token)
    }
}
