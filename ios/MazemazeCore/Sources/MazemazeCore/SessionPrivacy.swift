import Foundation

/// What may be written to disk about the pages a person visits (restoring tabs, "recent sites").
/// Fail closed: anything that could carry a login, a secret, a private mailbox or a private network
/// address is not stored. Query strings and fragments are never stored.
public enum SessionPrivacy {
    public static let maxURLLength = 500
    public static let maxTitleLength = 80

    static let extraSensitiveHostLabels: Set<String> = [
        "mail", "webmail", "bank", "banking", "secure", "pay", "payment", "cart", "checkout", "admin",
        "intranet", "vpn", "signin", "mypage", "billing", "wallet", "webbanking",
    ]
    static let sensitivePathWords: Set<String> = [
        "password", "passwd", "reset", "verify", "verification", "payment", "checkout", "cart", "order", "orders",
        "mypage", "account", "accounts", "billing", "invoice", "admin", "inbox", "mail", "webmail", "message",
        "messages", "dm", "login", "logout", "signin", "signup", "oauth", "oauth2", "auth", "sso", "token",
        "settings", "profile", "wallet", "bank",
    ]
    static let privateHostSuffixes = [".local", ".internal", ".lan", ".home", ".corp", ".localdomain", ".intranet", ".private", ".invalid", ".test", ".example", ".localhost"]

    /// The URL to store (https, host and path only), or nil if this page must not be stored.
    public static func persistableURL(_ url: URL?) -> URL? {
        guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard comps.scheme?.lowercased() == "https" else { return nil }
        guard comps.user == nil, comps.password == nil else { return nil }
        if let port = comps.port, port != 443 { return nil }
        guard var host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard isPublicHostName(host) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        if labels.contains(where: { SitePolicy.deniedHostLabels.contains($0) || extraSensitiveHostLabels.contains($0) }) { return nil }
        let path = comps.percentEncodedPath
        if SitePolicy.isDeniedPath(path) { return nil }
        let segments = SitePolicy.normalizedSegments(path)
        if segments.contains(where: { sensitivePathWords.contains($0) }) { return nil }
        var out = URLComponents()
        out.scheme = "https"
        out.host = host
        out.percentEncodedPath = path.isEmpty ? "/" : path
        guard let result = out.url, result.absoluteString.utf8.count <= maxURLLength else { return nil }
        return result
    }

    /// A public DNS name: ASCII, with a dot, not an IP address, not a local-network name.
    static func isPublicHostName(_ host: String) -> Bool {
        guard host.unicodeScalars.allSatisfy({ $0.isASCII }), host.contains("."), host.count <= 253 else { return false }
        if host == "localhost" || host.contains(":") { return false }
        if LocalHostPolicy.canonicalIPv4(host) != nil { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // An all-numeric name is an (odd) IP address.
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) { return false }
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
        return !privateHostSuffixes.contains(where: { host.hasSuffix($0) })
    }

    static let titleBlockedHosts = ["x.com", "twitter.com"]          // a post's text is its title
    static let searchPathWords: Set<String> = ["search", "results", "result", "find", "query", "q", "s", "hashtag", "explore", "tag", "tags", "keyword", "keywords", "topics", "topic", "検索"]
    /// The only sites whose page titles are ever stored (news sites). Sites the person adds later are not on
    /// this list: a social-network or forum page title can contain what somebody wrote.
    public static let titleHosts = ["news.yahoo.co.jp"]

    /// A page title may be stored only if it cannot contain what the person typed or someone posted: no query
    /// string, not a search page, not a social-media post.
    public static func titleMayBeStored(for original: URL) -> Bool {
        guard let comps = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return false }
        if comps.query != nil || comps.fragment != nil { return false }
        let host = (comps.host ?? "").lowercased()
        if titleBlockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        return !SitePolicy.normalizedSegments(comps.percentEncodedPath).contains { searchPathWords.contains($0) }
    }

    /// The title to store: the page title only for sites the person translates (news pages) and pages whose
    /// title is safe (see titleMayBeStored); otherwise just the host name (a mailbox, bank or search page
    /// title can reveal a lot). `original` is the URL before query and fragment were removed.
    public static func storableTitle(for url: URL, title: String?, allowedHosts: [String], original: URL? = nil) -> String {
        let host = url.host?.lowercased() ?? ""
        let allowed = allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard allowed, titleMayBeStored(for: original ?? url), let title else { return host }
        let cleaned = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0x200B...0x200F).contains($0.value)
                && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) && $0.value != 0xFEFF }
            .map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? host : String(cleaned.prefix(maxTitleLength))
    }
}

// MARK: - Favorites and recent sites

public struct SavedSite: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var visitedAt: Date?
    public init(id: UUID = UUID(), title: String, url: URL, visitedAt: Date? = nil) {
        self.id = id; self.title = title; self.url = url; self.visitedAt = visitedAt
    }
}

public enum Favorites {
    public static let maxFavorites = 40
    public static let maxRecents = 20
    static let credentialQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authorization", "api_key", "apikey", "key",
        "secret", "password", "passwd", "pwd", "session", "sessionid", "sid", "jsessionid", "code", "ticket", "jwt",
        "otp", "sig", "signature", "x-amz-signature", "x-amz-credential", "x-amz-security-token",
    ]
    static func isTrackingKey(_ k: String) -> Bool {
        k.hasPrefix("utm_") || ["fbclid", "gclid", "igshid", "msclkid", "yclid", "mc_eid"].contains(k)
    }

    /// A favorite is saved on purpose, so the query is kept, minus tracking parameters. Anything that
    /// looks like a credential, a login/private page or a non-https address is refused.
    public static func favoriteURL(_ url: URL?) -> URL? {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard comps.scheme?.lowercased() == "https", comps.user == nil, comps.password == nil else { return nil }
        guard let host = comps.host?.lowercased(), SessionPrivacy.isPublicHostName(host) else { return nil }
        if let port = comps.port, port != 443 { return nil }
        if SitePolicy.isDeniedPath(comps.percentEncodedPath) { return nil }
        let labels = host.split(separator: ".").map(String.init)
        if labels.contains(where: { SitePolicy.deniedHostLabels.contains($0) }) { return nil }
        var kept: [URLQueryItem] = []
        for item in comps.queryItems ?? [] {
            let k = item.name.removingPercentEncoding?.lowercased() ?? item.name.lowercased()
            if credentialQueryKeys.contains(k) { return nil }
            if isTrackingKey(k) { continue }
            kept.append(item)
        }
        comps.queryItems = kept.isEmpty ? nil : kept
        comps.fragment = nil
        comps.host = host
        guard let result = comps.url, result.absoluteString.utf8.count <= 1000 else { return nil }
        return result
    }

    /// Key used to recognise the same page twice.
    public static func dedupeKey(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.host = c.host?.lowercased(); c.scheme = c.scheme?.lowercased(); c.fragment = nil
        if c.port == 443 { c.port = nil }
        if c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path.isEmpty { c.path = "/" }
        return c.string ?? url.absoluteString
    }

    static func cleanTitle(_ raw: String, fallback: String) -> String {
        let t = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : String(t.prefix(SessionPrivacy.maxTitleLength))
    }
}

public struct BookmarkData: Codable, Equatable, Sendable {
    public var favorites: [SavedSite] = []
    public var recents: [SavedSite] = []
    public init() {}

    /// Returns false (nothing changed) when the page may not be saved. Re-adding moves it to the front.
    @discardableResult
    public mutating func addFavorite(url: URL, title: String) -> Bool {
        guard let safe = Favorites.favoriteURL(url) else { return false }
        let key = Favorites.dedupeKey(safe)
        favorites.removeAll { Favorites.dedupeKey($0.url) == key }
        favorites.insert(SavedSite(title: Favorites.cleanTitle(title, fallback: safe.host ?? "サイト"), url: safe), at: 0)
        if favorites.count > Favorites.maxFavorites { favorites.removeLast(favorites.count - Favorites.maxFavorites) }
        return true
    }

    public mutating func removeFavorite(id: UUID) { favorites.removeAll { $0.id == id } }
    public func isFavorite(_ url: URL) -> Bool {
        guard let safe = Favorites.favoriteURL(url) else { return false }
        let key = Favorites.dedupeKey(safe)
        return favorites.contains { Favorites.dedupeKey($0.url) == key }
    }

    /// Recent sites keep host and path only (no query), and only pages SessionPrivacy allows.
    public mutating func recordVisit(url: URL?, title: String?, allowedHosts: [String], now: Date = Date()) {
        guard let safe = SessionPrivacy.persistableURL(url) else { return }
        let key = Favorites.dedupeKey(safe)
        recents.removeAll { Favorites.dedupeKey($0.url) == key }
        recents.insert(SavedSite(title: SessionPrivacy.storableTitle(for: safe, title: title, allowedHosts: allowedHosts, original: url), url: safe, visitedAt: now), at: 0)
        if recents.count > Favorites.maxRecents { recents.removeLast(recents.count - Favorites.maxRecents) }
    }

    public mutating func clearRecents() { recents.removeAll() }
}

/// Stores BookmarkData in UserDefaults as JSON (a damaged value is ignored, never crashes).
public struct BookmarkStorage {
    let defaults: UserDefaults
    let key = "mazemaze.bookmarks.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> BookmarkData {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(BookmarkData.self, from: data) else { return BookmarkData() }
        var clean = BookmarkData()
        clean.favorites = Array(value.favorites.filter { Favorites.favoriteURL($0.url) != nil }.prefix(Favorites.maxFavorites))
        clean.recents = Array(value.recents.filter { SessionPrivacy.persistableURL($0.url) != nil }.prefix(Favorites.maxRecents))
        return clean
    }
    public func save(_ data: BookmarkData) {
        if let encoded = try? JSONEncoder().encode(data) { defaults.set(encoded, forKey: key); defaults.synchronize() }
    }
    public func clearAll() { defaults.removeObject(forKey: key) }
}

// MARK: - Tab restoration

/// The open tabs, reduced to what may be stored: a sanitized URL and a title for translated sites.
public struct TabsSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxTabs = 8
    public struct Entry: Codable, Equatable, Sendable {
        public var url: String?       // nil: the home screen
        public var title: String?
        public init(url: String?, title: String?) { self.url = url; self.title = title }
    }
    public var version = TabsSnapshot.currentVersion
    public var activeIndex = 0
    public var tabs: [Entry] = []
    public init() {}

    public static func make(tabs: [(url: URL?, title: String?)], activeIndex: Int, allowedHosts: [String]) -> TabsSnapshot {
        var snap = TabsSnapshot()
        for t in tabs.prefix(maxTabs) {
            if let safe = SessionPrivacy.persistableURL(t.url) {
                snap.tabs.append(Entry(url: safe.absoluteString, title: SessionPrivacy.storableTitle(for: safe, title: t.title, allowedHosts: allowedHosts, original: t.url)))
            } else {
                snap.tabs.append(Entry(url: nil, title: nil))      // a private page is restored as the home screen
            }
        }
        snap.activeIndex = snap.tabs.indices.contains(activeIndex) ? activeIndex : 0
        return snap
    }

    /// Validates again on the way in: stored data may be old, damaged or edited.
    public static func restore(from data: Data?, allowedHosts: [String]) -> TabsSnapshot? {
        guard let data, let raw = try? JSONDecoder().decode(TabsSnapshot.self, from: data), raw.version == currentVersion else { return nil }
        let tabs = raw.tabs.prefix(maxTabs).map { entry -> (URL?, String?) in
            (entry.url.flatMap(URL.init(string:)), entry.title)
        }
        guard !tabs.isEmpty else { return nil }
        return make(tabs: tabs.map { ($0.0, $0.1) }, activeIndex: raw.activeIndex, allowedHosts: allowedHosts)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
