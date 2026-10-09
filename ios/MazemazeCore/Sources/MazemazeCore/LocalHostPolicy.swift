import Foundation

/// The translation server must be on this Mac or the local network. Public hosts are refused so a
/// mistyped or malicious setting can never send page text or the token to the internet.
public enum LocalHostPolicy {
    public enum Rejection: Error, Equatable {
        case malformed, unsupportedScheme, hasCredentials, badPort, notLocal, unexpectedPath
    }

    /// Validates a base URL such as `http://192.168.0.19:8000`. Returns a normalized URL
    /// (scheme://host[:port]) or the reason it was refused. Strict by design: anything that is
    /// not an unambiguous dotted-quad IPv4, `localhost`, `::1` or a `*.local` name is refused,
    /// so the string that is checked is the host that is actually contacted.
    public static func validate(_ raw: String) -> Result<URL, Rejection> {
        validate(raw, accepting: isLocalHost)
    }

    /// The Mac's name on the owner's Tailscale network (`<mac>.<tailnet>.ts.net`), used
    /// away from home. Only ever accepted over https with a pinned certificate (see `SettingsStore.serverConfig`).
    public static func validateTailscale(_ raw: String) -> Result<URL, Rejection> {
        validate(raw, accepting: isTailscaleHost)
    }

    private static func validate(_ raw: String, accepting accept: (String) -> Bool) -> Result<URL, Rejection> {
        // No trimming here: whitespace, control characters or backslashes mean the string is
        // ambiguous between parsers.
        for scalar in raw.unicodeScalars where scalar.value <= 0x20 || scalar.value >= 0x7F || scalar == "\\" {
            return .failure(.malformed)
        }
        guard !raw.isEmpty, let comps = URLComponents(string: raw) else { return .failure(.malformed) }
        guard let scheme = comps.scheme?.lowercased() else { return .failure(.malformed) }
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme) }
        if comps.user != nil || comps.password != nil { return .failure(.hasCredentials) }
        guard comps.query == nil, comps.fragment == nil, comps.path.isEmpty || comps.path == "/" else {
            return .failure(.unexpectedPath)
        }
        if let port = comps.port, !(1...65535).contains(port) { return .failure(.badPort) }
        guard var host = comps.host?.lowercased(), !host.isEmpty else { return .failure(.malformed) }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard accept(host) else { return .failure(.notLocal) }

        var out = URLComponents()
        out.scheme = scheme
        out.host = host.contains(":") ? "[\(host)]" : host
        out.port = comps.port
        guard let url = out.url, let rehost = url.host?.lowercased() else { return .failure(.malformed) }
        let normalized = rehost.hasPrefix("[") ? String(rehost.dropFirst().dropLast()) : rehost
        guard normalized == host else { return .failure(.malformed) }  // parser differential
        return .success(url)
    }

    public static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        if host.contains(":") { return false }  // every other IPv6 form is refused
        if let octets = canonicalIPv4(host) { return isPrivate(octets) }
        return isMulticastDNSName(host)
    }

    /// A `<node>.<tailnet>.ts.net` name (lowercase letters, digits, hyphens). IP addresses (100.64.0.0/10) are not
    /// accepted: the app's ATS exception covers `ts.net` names only, and a name survives an address change.
    public static func isTailscaleHost(_ host: String) -> Bool {
        guard host.hasSuffix(".ts.net"), host.count > ".ts.net".count, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 4 && labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-") &&
                l.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" }
        }
    }

    /// Only canonical decimal dotted-quad ("192.168.0.1"); "0177.0.0.1", "127.1", "2130706433",
    /// "0x7f000001" are not accepted as addresses.
    static func canonicalIPv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            if p.count > 1 && p.first == "0" { return nil }
            guard let n = Int(p), n <= 255 else { return nil }
            out.append(n)
        }
        return out
    }

    static func isPrivate(_ o: [Int]) -> Bool {
        if o[0] == 10 || o[0] == 127 { return true }
        if o[0] == 172 && (16...31).contains(o[1]) { return true }
        if o[0] == 192 && o[1] == 168 { return true }
        return false
    }

    static func isMulticastDNSName(_ host: String) -> Bool {
        guard host.hasSuffix(".local"), host.count > ".local".count, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-") &&
                l.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" }
        }
    }
}
