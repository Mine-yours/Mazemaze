import Foundation
import CryptoKit

public enum PairingError: Error, Equatable {
    case malformed, unsupportedVersion, unknownParameter(String), duplicateParameter(String), missing(String), invalid(String)

    public var message: String {
        switch self {
        case .malformed: return "ペアリング情報として読み取れません。Mac に表示された QR か、そのすぐ下の文字列をそのまま使ってください。"
        case .unsupportedVersion: return "この Mazemaze（アプリ）では読み取れない形式です。アプリと Mac 側のスクリプトを最新にしてください。"
        case .unknownParameter(let k): return "ペアリング情報に未知の項目（\(k)）があるため、安全のため使いません。"
        case .duplicateParameter(let k): return "ペアリング情報の項目（\(k)）が重複しているため、使いません。"
        case .missing(let k): return "ペアリング情報に必要な項目（\(k)）がありません。"
        case .invalid(let k): return "ペアリング情報の項目（\(k)）が正しくないため、使いません。"
        }
    }
}

/// What the Mac shows (as a QR code and as text) so the iPhone can be set up without typing:
///   mazemaze://pair?v=1&h=<mac>.local&i=<192.168.x.x>&p=8000&t=<token>&s=https&f=<sha256 of the certificate>&ts=<mac>.<tailnet>.ts.net
/// The QR code travels from the Mac's screen to the iPhone's camera, not over the network, so the token
/// is never exposed on the Wi-Fi while pairing. Nothing here is applied without the person confirming it.
public struct PairingPayload: Equatable, Sendable {
    public enum Scheme: String, Sendable { case http, https }
    public let scheme: Scheme
    public let host: String?             // "<name>.local"
    public let ip: String?               // a private IPv4 address
    public let port: Int
    public let token: String
    public let fingerprint: String?      // SHA-256 of the server certificate (lowercase hex), https only
    public let name: String?
    public let tailscale: String?        // the Mac's Tailscale name (<mac>.<tailnet>.ts.net), https only

    static let allowedKeys: Set<String> = ["v", "h", "i", "p", "t", "s", "f", "n", "ts"]

    public static func parse(_ raw: String) -> Result<PairingPayload, PairingError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 600, text.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F }),
              let comps = URLComponents(string: text) else { return .failure(.malformed) }
        guard comps.scheme?.lowercased() == "mazemaze", comps.host?.lowercased() == "pair", comps.user == nil, comps.password == nil,
              comps.port == nil, comps.fragment == nil, comps.path.isEmpty || comps.path == "/" else { return .failure(.malformed) }
        var values: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            guard allowedKeys.contains(item.name) else { return .failure(.unknownParameter(String(item.name.prefix(12)))) }
            guard values[item.name] == nil else { return .failure(.duplicateParameter(item.name)) }
            guard let value = item.value, !value.isEmpty else { return .failure(.invalid(item.name)) }
            values[item.name] = value
        }
        guard let version = values["v"] else { return .failure(.missing("v")) }
        guard version == "1" else { return .failure(.unsupportedVersion) }

        let scheme: Scheme
        switch values["s"] ?? "http" {
        case "http": scheme = .http
        case "https": scheme = .https
        default: return .failure(.invalid("s"))
        }

        var host: String?
        if let h = values["h"] {
            let lower = h.lowercased()
            guard LocalHostPolicy.isMulticastDNSName(lower) else { return .failure(.invalid("h")) }
            host = lower
        }
        var ip: String?
        if let i = values["i"] {
            guard let octets = LocalHostPolicy.canonicalIPv4(i), LocalHostPolicy.isPrivate(octets) else { return .failure(.invalid("i")) }
            ip = i
        }
        guard host != nil || ip != nil else { return .failure(.missing("h")) }

        guard let p = values["p"], p.count <= 5, p.allSatisfy({ $0 >= "0" && $0 <= "9" }), let port = Int(p), (1...65535).contains(port), !(p.count > 1 && p.hasPrefix("0")) else {
            return .failure(values["p"] == nil ? .missing("p") : .invalid("p"))
        }
        guard let t = values["t"] else { return .failure(.missing("t")) }
        guard (16...128).contains(t.count), t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return .failure(.invalid("t")) }

        var fingerprint: String?
        if let f = values["f"] {
            guard scheme == .https, let normalized = PinEvaluator.normalizeFingerprint(f) else { return .failure(.invalid("f")) }
            fingerprint = normalized
        } else if scheme == .https {
            return .failure(.missing("f"))        // encrypted but unauthenticated would be pointless
        }

        var tailscale: String?
        if let ts = values["ts"] {
            // Away from home the traffic crosses networks the owner does not control, so it is only accepted
            // encrypted and pinned to the paired certificate.
            let lower = ts.lowercased()
            guard scheme == .https, LocalHostPolicy.isTailscaleHost(lower) else { return .failure(.invalid("ts")) }
            tailscale = lower
        }

        var name: String?
        if let n = values["n"] {
            // URLComponents has already decoded the value. Drop control, zero-width and bidi-control characters
            // (the name is shown in the confirmation prompt and must not be able to disguise it).
            let hidden: (Unicode.Scalar) -> Bool = { $0.value < 0x20 || $0.value == 0x7F || (0x200B...0x200F).contains($0.value) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) || $0.value == 0xFEFF }
            name = String(String(String.UnicodeScalarView(n.unicodeScalars.filter { !hidden($0) })).prefix(40))
        }
        return .success(PairingPayload(scheme: scheme, host: host, ip: ip, port: port, token: t, fingerprint: fingerprint, name: name, tailscale: tailscale))
    }

    /// The address to try first: the `.local` name (it keeps working when the Mac's IP address changes).
    public var primaryURL: URL { url(host ?? ip ?? "") }
    /// The IP address, tried when the `.local` name cannot be found.
    public var fallbackURL: URL? { (host != nil && ip != nil) ? url(ip!) : nil }

    /// The Tailscale address, tried last (away from home).
    public var tailscaleURL: URL? { tailscale.map { url($0) } }

    private func url(_ h: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme.rawValue; c.host = h; c.port = port
        return c.url!
    }

    public var isEncrypted: Bool { scheme == .https }
    /// The first 16 hex digits, as the Mac prints them (so the two can be compared).
    public var shortFingerprint: String? { fingerprint.map { String($0.prefix(16)) + "…" } }
}

// MARK: - certificate pinning

public enum PinEvaluator {
    public enum Decision: Equatable { case accept, mismatch, notPinned }

    /// 64 hex digits (colons / spaces / case ignored) -> lowercase hex. Anything else (SHA-1, MD5, junk): nil.
    public static func normalizeFingerprint(_ raw: String) -> String? {
        let hex = raw.filter { $0 != ":" && $0 != " " }.lowercased()
        guard hex.count == 64, hex.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) else { return nil }
        return hex
    }

    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The server is accepted only if its leaf certificate is the one that was paired. The host name is
    /// deliberately not compared: the Mac's IP address and name may change, the certificate does not.
    public static func evaluate(chainDER: [Data], expected: String?) -> Decision {
        guard let expected = expected.flatMap(normalizeFingerprint) else { return .notPinned }
        guard let leaf = chainDER.first else { return .mismatch }
        return fingerprint(of: leaf) == expected ? .accept : .mismatch
    }
}

/// Thrown by the transport when a pinned server presented a different certificate. Nothing was sent.
public struct PinMismatchError: Error, Equatable { public init() {} }
