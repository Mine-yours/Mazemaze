import Foundation

/// Chooses which address of the Mac to talk to: the `.local` name first (it survives IP changes), the IP
/// address if the name cannot be found. It only asks "is a Mazemaze server answering here?" without the
/// token, so the token is never sent to a host that has not shown itself to be the server.
public actor EndpointResolver {
    private let transport: HTTPTransport
    private let clock: ServiceClock
    private let ttl: TimeInterval
    private var cache: (key: [URL], url: URL, at: TimeInterval)?
    private var failedAt: (key: [URL], at: TimeInterval)?           // nobody answered: do not wait for them again right away
    private let failureMemory: TimeInterval = 10

    public init(transport: HTTPTransport, clock: ServiceClock = SystemClock(), ttl: TimeInterval = 120) {
        self.transport = transport; self.clock = clock; self.ttl = ttl
    }

    public func resolve(_ cfg: ServerConfig) async -> URL {
        guard cfg.candidates.count > 1 else { return cfg.baseURL }
        if let c = cache, c.key == cfg.candidates, clock.now() - c.at < ttl { return c.url }
        if let f = failedAt, f.key == cfg.candidates, clock.now() - f.at < failureMemory { return cfg.baseURL }
        for url in cfg.candidates where await answers(url) {
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

    func answers(_ base: URL) async -> Bool {
        let request = HTTPRequest(url: base.appendingPathComponent("api/status"), method: "GET", headers: ["Accept": "application/json"], timeout: 3)
        guard let response = try? await transport.send(request) else { return false }
        return Self.looksLikeMazemaze(response)
    }
}
