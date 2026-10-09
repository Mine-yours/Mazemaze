import Foundation

/// Chooses which address of the Mac to talk to: the `.local` name first (it survives IP changes), the IP
/// address if the name cannot be found, and the Tailscale address (away from home) last. It only asks "is a Mazemaze server answering here?" without the
/// token, so the token is never sent to a host that has not shown itself to be the server.
/// What happened when one address was asked "are you a Mazemaze server?" (shown to help find a connection problem).
public enum ProbeOutcome: Equatable, Sendable {
    case answered, notMazemaze(status: Int), pinMismatch, timedOut, refused, notFound, unreachable(code: Int), failed

    public var text: String {
        switch self {
        case .answered: return "応答あり"
        case .notMazemaze(let st): return "別の機器が応答（HTTP \(st)）"
        case .pinMismatch: return "証明書が違う"
        case .timedOut: return "応答なし（時間切れ）"
        case .refused: return "接続拒否"
        case .notFound: return "名前が見つからない"
        case .unreachable(let c): return "届かない（\(c)）"
        case .failed: return "失敗"
        }
    }
}

public struct ProbeResult: Equatable, Sendable {
    public enum Role: String, Sendable { case name = "Mac の名前", ip = "家の IP アドレス", tailscale = "Tailscale（外出先）" }
    public let role: Role
    public let outcome: ProbeOutcome
}

public actor EndpointResolver {
    private let transport: HTTPTransport
    private let clock: ServiceClock
    private let ttl: TimeInterval
    private var cache: (key: [URL], url: URL, at: TimeInterval)?
    private var failedAt: (key: [URL], at: TimeInterval)?           // nobody answered: do not wait for them again right away
    private let failureMemory: TimeInterval = 10
    public private(set) var lastProbes: [ProbeResult] = []

    public init(transport: HTTPTransport, clock: ServiceClock = SystemClock(), ttl: TimeInterval = 120) {
        self.transport = transport; self.clock = clock; self.ttl = ttl
    }

    public func resolve(_ cfg: ServerConfig) async -> URL {
        guard cfg.candidates.count > 1 else { return cfg.baseURL }
        if let c = cache, c.key == cfg.candidates, clock.now() - c.at < ttl { return c.url }
        if let f = failedAt, f.key == cfg.candidates, clock.now() - f.at < failureMemory { return cfg.baseURL }
        // With a Tailscale address the home addresses get a short look first (at home they answer within a
        // moment), so being away does not mean waiting for every home address to time out before the last one.
        var probes: [ProbeResult] = []
        for (i, url) in cfg.candidates.enumerated() {
            let isTailscale = cfg.tailscaleURL != nil && i == cfg.candidates.count - 1
            let timeout: TimeInterval = isTailscale ? Self.tailscaleTimeout : (cfg.tailscaleURL != nil ? Self.homeTimeout : Self.defaultTimeout)
            let outcome = await probe(url, timeout: timeout)
            probes.append(ProbeResult(role: i == 0 ? .name : (isTailscale ? .tailscale : .ip), outcome: outcome))
            lastProbes = probes                    // published as a whole: overlapping resolves do not mix their lists
            guard outcome == .answered else { continue }
            cache = (cfg.candidates, url, clock.now())
            failedAt = nil
            return url
        }
        cache = nil
        failedAt = (cfg.candidates, clock.now())
        return cfg.baseURL
    }

    /// A Mazemaze server answers /api/status with its own JSON (status, or one of its error codes). Any
    /// other device that merely says "401" or "403" (a router, a NAS, a printer) is not accepted.
    static func looksLikeMazemaze(_ r: HTTPResponse) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { return false }
        switch r.status {
        case 200: return json["model"] is String && json["allowed_models"] is [Any]
        case 400, 401, 403:
            let code = (json["error"] as? [String: Any])?["code"] as? String
            return ["bad_host", "token_required", "forbidden"].contains(code ?? "")
        default: return false
        }
    }

    /// Forget the choice (the last request failed): the next request looks again.
    public func invalidate() { cache = nil; failedAt = nil }

    static let defaultTimeout: TimeInterval = 3
    static let homeTimeout: TimeInterval = 1.5          // a home address, while a Tailscale address can still be tried
    static let tailscaleTimeout: TimeInterval = 6       // the tunnel may need a moment to come up over cellular

    func answers(_ base: URL, timeout: TimeInterval = EndpointResolver.defaultTimeout) async -> Bool {
        await probe(base, timeout: timeout) == .answered
    }

    func probe(_ base: URL, timeout: TimeInterval) async -> ProbeOutcome {
        let request = HTTPRequest(url: base.appendingPathComponent("api/status"), method: "GET", headers: ["Accept": "application/json"], timeout: timeout)
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch is PinMismatchError { return .pinMismatch }
        catch let e as URLError {
            switch e.code {
            case .timedOut: return .timedOut
            case .cannotConnectToHost: return .refused
            case .cannotFindHost, .dnsLookupFailed: return .notFound
            default: return .unreachable(code: e.errorCode)
            }
        }
        catch { return .failed }
        return Self.looksLikeMazemaze(response) ? .answered : .notMazemaze(status: response.status)
    }
}
