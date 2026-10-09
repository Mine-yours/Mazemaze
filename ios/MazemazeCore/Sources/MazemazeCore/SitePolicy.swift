import Foundation

public enum SiteDecision: Equatable {
    case allowed(profile: SiteProfile)
    case denied(String)
    public var isAllowed: Bool { if case .allowed = self { return true } else { return false } }
}

/// Which DOM strategy translator.js uses. Chosen by Swift from the verified URL, never by the page.
public enum SiteProfile: String, Equatable { case x, generic }

/// Decides on which pages text may be translated (and therefore sent to the Mac). Everything not
/// explicitly allowed is refused.
public struct SitePolicy: Equatable {
    public static let defaultAllowedHosts = ["x.com", "twitter.com", "news.yahoo.co.jp"]
    static let publicSuffixLike: Set<String> = [
        "com", "net", "org", "jp", "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.uk", "io", "dev", "app",
        // Shared hosting suffixes: allowing one would allow every tenant of that service.
        "github.io", "gitlab.io", "blogspot.com", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev",
        "workers.dev", "web.app", "firebaseapp.com", "wordpress.com", "tumblr.com", "appspot.com", "azurewebsites.net",
        "cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "fc2.com", "hatenablog.com", "hateblo.jp", "livedoor.blog",
    ]
    static let deniedHostLabels: Set<String> = ["login", "accounts", "account", "auth", "signin", "sso", "id", "oauth"]
    /// Path prefixes (by whole segments) that are never translated: sign-in flows, DMs, settings.
    static let deniedPaths: [[String]] = [
        ["login"], ["logout"], ["signin"], ["signup"], ["oauth"], ["oauth2"], ["account"], ["settings"],
        ["messages"], ["compose"], ["i", "flow"], ["i", "oauth2"], ["i", "chat"], ["i", "messages"],
    ]

    public var allowedHosts: [String]
    /// DEBUG builds only: also allow plain-HTTP localhost pages for the simulator self-test.
    public var allowInsecureLocalhost: Bool

    public init(allowedHosts: [String] = SitePolicy.defaultAllowedHosts, allowInsecureLocalhost: Bool = false) {
        self.allowedHosts = allowedHosts
        self.allowInsecureLocalhost = allowInsecureLocalhost
    }

    /// Normalizes a user-entered host for the allow-list; nil if it is unsafe (a bare TLD, a public
    /// suffix, an IP address, wildcards, non-ASCII, etc.).
    public static func normalizeEntry(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, s.count <= 253, s.contains("."), !publicSuffixLike.contains(s) else { return nil }
        // Names that are reserved / never public (RFC 6761 etc.) are not sites.
        guard !["invalid", "test", "example", "localhost", "local"].contains(where: { s == $0 || s.hasSuffix("." + $0) }) else { return nil }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-") &&
                l.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" }
        }) else { return nil }
        // All-numeric labels would be an IP address.
        if labels.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) { return nil }
        // The last label must contain a letter (a real TLD).
        guard let tld = labels.last, tld.contains(where: { $0 >= "a" && $0 <= "z" }) else { return nil }
        return s
    }

    public func decision(for url: URL?) -> SiteDecision {
        // The app's own paste page is decided before anything else (exact match only); the rest of that host never is.
        if PasteSurface.isPasteURL(url) { return .allowed(profile: .generic) }
        if PasteSurface.touchesPasteHost(url) { return .denied("対象外のホストです") }
        guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .denied("URL がありません") }
        guard let scheme = comps.scheme?.lowercased() else { return .denied("スキームがありません") }
        if comps.user != nil || comps.password != nil { return .denied("認証情報付きの URL です") }
        guard var host = comps.host?.lowercased(), !host.isEmpty else { return .denied("ホストがありません") }
        if host.hasSuffix(".") { host.removeLast() }
        let isLocalTest = allowInsecureLocalhost && (host == "localhost" || host == "127.0.0.1")
        if scheme == "http" {
            guard isLocalTest else { return .denied("HTTPS 以外のページは翻訳しません") }
        } else if scheme != "https" {
            return .denied("対応していないスキームです")
        }
        if scheme == "https", let port = comps.port, port != 443 { return .denied("標準ポート以外は翻訳しません") }
        guard host.unicodeScalars.allSatisfy({ $0.isASCII }) else { return .denied("対象外のホストです") }
        let labels = host.split(separator: ".").map(String.init)
        if !isLocalTest {
            guard allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                return .denied("許可したサイトではありません")
            }
            if labels.contains(where: { Self.deniedHostLabels.contains($0) }) { return .denied("ログイン関連のページです") }
        }
        if Self.isDeniedPath(comps.percentEncodedPath) { return .denied("ログイン・DM・設定などのページです") }
        let isX = host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com")
        if isX && !Self.isAllowedXPath(comps.percentEncodedPath) { return .denied("X のタイムライン・投稿・プロフィール以外は翻訳しません") }
        return .allowed(profile: isX ? .x : .generic)
    }

    static let xContentRoots: Set<String> = ["home", "explore", "search", "hashtag"]
    static let xReservedFirstSegments: Set<String> = [
        "i", "settings", "messages", "compose", "login", "logout", "signup", "account", "tos", "privacy",
        "intent", "share", "jobs", "notifications", "bookmarks", "lists", "communities", "premium",
        "verified", "download", "about", "help", "rules", "oauth", "oauth2", "flow", "api", "search-advanced",
    ]

    /// X is allow-list based: the timeline, search, hashtags, profiles and posts only.
    static func isAllowedXPath(_ percentEncodedPath: String) -> Bool {
        let segments = normalizedSegments(percentEncodedPath)
        guard let first = segments.first else { return true }   // "/" is the home timeline
        if xContentRoots.contains(first) { return true }
        if xReservedFirstSegments.contains(first) { return false }
        // "/<handle>" and "/<handle>/status/<id>": 1-15 letters, digits, underscore.
        return first.count <= 15 && first.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "_"
        }
    }

    static func normalizedSegments(_ percentEncodedPath: String) -> [String] {
        let decoded = percentEncodedPath.removingPercentEncoding ?? percentEncodedPath
        var segments: [String] = []
        for part in decoded.lowercased().split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = segments.popLast(); continue }
            segments.append(String(part))
        }
        return segments
    }

    static func isDeniedPath(_ percentEncodedPath: String) -> Bool {
        let segments = normalizedSegments(percentEncodedPath)
        return deniedPaths.contains { prefix in
            segments.count >= prefix.count && Array(segments.prefix(prefix.count)) == prefix
        }
    }
}
