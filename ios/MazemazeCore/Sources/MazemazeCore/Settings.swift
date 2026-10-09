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
    /// Tried when `baseURL` (usually a `.local` name) cannot be reached: the Mac's IP address.
    public var fallbackURL: URL?
    /// SHA-256 of the certificate the server must present (https only). Nil: no pinning.
    public var pinnedFingerprint: String?
    /// Tried last, away from home: the Mac's address on the owner's Tailscale network (https + pinned only).
    public var tailscaleURL: URL?
    public init(baseURL: URL, token: String?, fallbackURL: URL? = nil, pinnedFingerprint: String? = nil, tailscaleURL: URL? = nil) {
        self.baseURL = baseURL; self.token = token; self.fallbackURL = fallbackURL; self.pinnedFingerprint = pinnedFingerprint
        self.tailscaleURL = tailscaleURL
    }
    public var candidates: [URL] { [baseURL] + (fallbackURL.map { [$0] } ?? []) + (tailscaleURL.map { [$0] } ?? []) }
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
        static let fallbackURL = "mazemaze.fallbackURL"
        static let tailscaleURL = "mazemaze.tailscaleURL"
        static let pin = "mazemaze.pin"
        static let serverName = "mazemaze.serverName"
        static let restoreTabs = "mazemaze.restoreTabs"
        static let safariIdentityForX = "mazemaze.safariIdentityForX"
        static let autoHideBars = "mazemaze.autoHideBars"
        static let embedDictionary = "mazemaze.embedDictionary"
        static let autoMeaning = "mazemaze.autoMeaning"
        static let embedDictionaryCrashed = "mazemaze.embedDictionaryCrashed"
        static let recents = "mazemaze.recentsEnabled"
        static let tabs = "mazemaze.tabs.v1"
    }

    public init(defaults: UserDefaults = .standard, secrets: SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public var serverURLString: String {
        get { defaults.string(forKey: Key.serverURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.serverURL) }
    }
    public var fallbackURLString: String {
        get { defaults.string(forKey: Key.fallbackURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.fallbackURL) }
    }
    public var pinnedFingerprint: String? {
        get { defaults.string(forKey: Key.pin).flatMap(PinEvaluator.normalizeFingerprint) }
        set { defaults.set(newValue.flatMap(PinEvaluator.normalizeFingerprint), forKey: Key.pin) }
    }
    public var serverName: String {
        get { defaults.string(forKey: Key.serverName) ?? "" }
        set { defaults.set(newValue, forKey: Key.serverName) }
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
    /// Reopen the tabs of the last session (only pages that are safe to store; see SessionPrivacy).
    /// On by default (owner's decision, 2026-10-09): X is opened with a Safari-style user agent.
    public var safariIdentityForX: Bool {
        get { defaults.object(forKey: Key.safariIdentityForX) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.safariIdentityForX) }
    }

    /// A word saved from the iPhone's dictionary gets its meaning looked up in the background (on by default).
    public var autoMeaning: Bool {
        get { defaults.object(forKey: Key.autoMeaning) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoMeaning) }
    }

    /// Show the iPhone's dictionary inside the lookup sheet (on by default). It switches itself off if the app ever died while
    /// showing it, and says so (`embedDictionaryCrashed`); the person can switch it on again.
    public var embedDictionary: Bool {
        get { defaults.object(forKey: Key.embedDictionary) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.embedDictionary); if newValue { defaults.set(false, forKey: Key.embedDictionaryCrashed) } }
    }
    public var embedDictionaryCrashed: Bool {
        get { defaults.bool(forKey: Key.embedDictionaryCrashed) }
        set { defaults.set(newValue, forKey: Key.embedDictionaryCrashed) }
    }

    /// The address bar and toolbar slide away while reading (scroll down) and return on scrolling up. On by default.
    public var autoHideBars: Bool {
        get { defaults.object(forKey: Key.autoHideBars) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoHideBars) }
    }

    public var restoreTabs: Bool {
        get { defaults.object(forKey: Key.restoreTabs) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.restoreTabs) }
    }
    /// Remember recently opened (safe, public) sites for the home screen.
    public var recentsEnabled: Bool {
        get { defaults.object(forKey: Key.recents) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.recents) }
    }
    public var savedTabsData: Data? {
        get { defaults.data(forKey: Key.tabs) }
        set { if let newValue { defaults.set(newValue, forKey: Key.tabs) } else { defaults.removeObject(forKey: Key.tabs) } }
    }
    public var userDefaults: UserDefaults { defaults }
    public var tailscaleURLString: String {
        get { defaults.string(forKey: Key.tailscaleURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.tailscaleURL) }
    }
    /// Ask the system to write preferences to disk now (they are normally written a little later, and a
    /// force-quit right after a change could lose it). Called after pairing, tab and bookmark changes.
    public func flush() { defaults.synchronize() }

    public var allowedHosts: [String] {
        get { (defaults.array(forKey: Key.hosts) as? [String]).map { $0.compactMap(SitePolicy.normalizeEntry) } ?? SitePolicy.defaultAllowedHosts }
        set { defaults.set(newValue.compactMap(SitePolicy.normalizeEntry), forKey: Key.hosts) }
    }

    /// The validated server configuration, or nil if the URL is missing or not a local address.
    public func serverConfig() -> ServerConfig? {
        guard case .success(let url) = LocalHostPolicy.validate(serverURLString) else { return nil }
        let pin = pinnedFingerprint
        // A pinned server must be reached over https; never fall back to plain http (a downgrade).
        if pin != nil, url.scheme != "https" { return nil }
        // The IP-address fallback is only ever used after that address answered like a Mazemaze server
        // (EndpointResolver); with a pinned certificate the certificate is checked as well.
        var fallback: URL?
        if case .success(let f) = LocalHostPolicy.validate(fallbackURLString), f.scheme == url.scheme { fallback = f }
        // The Tailscale address is only used with a pinned https server (it is reached over other people's networks).
        var tailscale: URL?
        if pin != nil, url.scheme == "https", case .success(let t) = LocalHostPolicy.validateTailscale(tailscaleURLString), t.scheme == "https" { tailscale = t }
        return ServerConfig(baseURL: url, token: token, fallbackURL: fallback, pinnedFingerprint: pin, tailscaleURL: tailscale)
    }

    /// Store a confirmed pairing: address(es), fingerprint and token together (the token goes to the Keychain).
    public func apply(_ pairing: PairingPayload) throws {
        let previous = (serverURLString, fallbackURLString, pinnedFingerprint, serverName, secrets.token(), tailscaleURLString)
        do {
            try secrets.setToken(pairing.token)
        } catch { throw error }
        serverURLString = pairing.primaryURL.absoluteString
        fallbackURLString = pairing.fallbackURL?.absoluteString ?? ""
        tailscaleURLString = pairing.tailscaleURL?.absoluteString ?? ""
        pinnedFingerprint = pairing.fingerprint
        serverName = pairing.name ?? pairing.host ?? ""
        defer { flush() }
        if serverConfig() == nil {              // refuse a combination the app would not accept
            serverURLString = previous.0; fallbackURLString = previous.1; pinnedFingerprint = previous.2; serverName = previous.3
            tailscaleURLString = previous.5
            try? secrets.setToken(previous.4)
            throw PairingError.invalid("h")
        }
    }
}
