import Foundation

public protocol ServiceClock: Sendable {
    func now() -> TimeInterval
    func sleep(seconds: Double) async throws
}

public struct SystemClock: ServiceClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
}

public enum TranslationFailure: Equatable, Sendable {
    case stale, cancelled, notConfigured, unauthorized, busy, unreachable, timeout, invalidResponse, limitReached
    case rejected(String), server(String), breakerOpen(Int)

    public var code: String {
        switch self {
        case .stale: return "stale"
        case .cancelled: return "cancelled"
        case .notConfigured: return "not_configured"
        case .unauthorized: return "unauthorized"
        case .busy: return "busy"
        case .unreachable: return "unreachable"
        case .timeout: return "timeout"
        case .invalidResponse: return "invalid_response"
        case .limitReached: return "limit_reached"
        case .rejected: return "rejected"
        case .server: return "server"
        case .breakerOpen: return "paused"
        }
    }

    /// Short Japanese status for the toolbar / settings. Never contains page text or the token.
    public var message: String {
        switch self {
        case .stale: return "ページが切り替わりました"
        case .cancelled: return "中断されました"
        case .notConfigured: return "翻訳サーバーが未設定です（設定で URL を入力）"
        case .unauthorized: return "トークンが違います（設定を確認）"
        case .busy: return "Mac が他の翻訳を処理中です。空き次第、自動で続きます"
        case .unreachable: return "Mac に接続できません。Mac で run_lan.sh が動いているか、同じ Wi-Fi か、iPhone の設定 > Mazemaze > ローカルネットワークが許可されているか確認してください"
        case .timeout: return "Mac の応答が遅すぎます。しばらくして、ページを開き直してください"
        case .invalidResponse: return "翻訳サーバーの応答を読み取れませんでした"
        case .limitReached: return "このページの翻訳回数の上限に達しました。ページを再読み込みすると続きます"
        case .rejected(let m), .server(let m): return m
        case .breakerOpen(let s): return "翻訳サーバーのエラーが続いたため、約 \(s) 秒間停止します"
        }
    }
}

public enum TranslationOutcome: Equatable, Sendable {
    case success([TranslatedSegment])
    case failure(TranslationFailure)

    /// A plist/JSON-compatible dictionary for the page-side script. Only the pieces the script
    /// needs; no URLs, no token.
    public func bridgePayload() -> [String: Any] {
        switch self {
        case .success(let segs):
            return ["ok": true, "segments": segs.map { ["kind": $0.kind.rawValue, "source": $0.source, "display": $0.display] }]
        case .failure(let f):
            return ["ok": false, "error": f.code, "message": f.message]
        }
    }
}

/// Serializes all translation requests (the Mac server handles one at a time), drops requests from
/// an old page generation, caches results in memory only, retries "busy" replies, and pauses after
/// repeated server failures. An in-flight HTTP call is never cancelled on page change: the server
/// cannot stop it either, so we let it finish (its result is cached) and just answer "stale".
public actor TranslationService {
    public struct Options: Sendable {
        public var cacheCapacity = 300
        public var maxRetriesOn429 = 6
        public var requestTimeout: TimeInterval = 200
        public var breakerThreshold = 3
        public var breakerCooldown: TimeInterval = 30
        public var maxRequestsPerGeneration = 600
        public init() {}
    }

    struct CacheKey: Hashable { let server: String; let text: String; let ratioMilli: Int; let unit: TranslationUnit }
    struct Waiter { let id: UUID; let gen: Int; let cont: CheckedContinuation<Bool, Never> }
    struct Payload: Encodable { let text: String; let ratio: Double; let unit: String }

    private let transport: HTTPTransport
    private let config: @Sendable () -> ServerConfig?
    private let prefs: @Sendable () -> (ratio: Double, unit: TranslationUnit)
    private let clock: ServiceClock
    private let options: Options

    public private(set) var generation = 0
    private var busy = false
    private var waiters: [Waiter] = []
    private var cache: [CacheKey: [TranslatedSegment]] = [:]
    private var cacheOrder: [CacheKey] = []
    private var consecutiveFailures = 0
    private var breakerOpenUntil: TimeInterval?
    private var requestsInGeneration = 0

    public init(transport: HTTPTransport,
                config: @escaping @Sendable () -> ServerConfig?,
                prefs: @escaping @Sendable () -> (ratio: Double, unit: TranslationUnit),
                clock: ServiceClock = SystemClock(),
                options: Options = Options()) {
        self.transport = transport; self.config = config; self.prefs = prefs; self.clock = clock; self.options = options
    }

    // MARK: generation
    @discardableResult
    public func bumpGeneration() -> Int {
        generation += 1
        requestsInGeneration = 0
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.cont.resume(returning: false) }
        return generation
    }

    /// Server URL / token / ratio changed: nothing cached for the old settings may be reused.
    public func configurationChanged() {
        cache.removeAll(); cacheOrder.removeAll()
        consecutiveFailures = 0; breakerOpenUntil = nil
        bumpGeneration()
    }

    public var cachedCount: Int { cache.count }
    public var isPaused: Bool { if let u = breakerOpenUntil { return clock.now() < u } else { return false } }

    // MARK: serialization
    private func acquire(gen: Int) async -> Bool {
        if gen != generation { return false }
        if !busy { busy = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { cont.resume(returning: false); return }
                waiters.append(Waiter(id: id, gen: gen, cont: cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) {
            let w = waiters.remove(at: i)
            w.cont.resume(returning: false)
        }
    }

    private func release() {
        while !waiters.isEmpty {
            let w = waiters.removeFirst()
            if w.gen == generation { w.cont.resume(returning: true); return }   // hand the slot over
            w.cont.resume(returning: false)
        }
        busy = false
    }

    // MARK: cache
    private func cached(_ key: CacheKey) -> [TranslatedSegment]? {
        guard let v = cache[key] else { return nil }
        if let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i) }
        cacheOrder.append(key)
        return v
    }

    private func store(_ key: CacheKey, _ value: [TranslatedSegment]) {
        if cache[key] == nil, cache.count >= options.cacheCapacity, let oldest = cacheOrder.first {
            cacheOrder.removeFirst(); cache[oldest] = nil
        }
        cache[key] = value
        if let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i) }
        cacheOrder.append(key)
    }

    // MARK: breaker
    private func breakerRemaining() -> Int? {
        guard let u = breakerOpenUntil else { return nil }
        let r = u - clock.now()
        return r > 0 ? Int(r.rounded(.up)) : nil
    }
    private func noteFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= options.breakerThreshold { breakerOpenUntil = clock.now() + options.breakerCooldown }
    }
    private func noteSuccess() { consecutiveFailures = 0; breakerOpenUntil = nil }

    // MARK: translate
    public func translate(gen: Int, text: String) async -> TranslationOutcome {
        guard gen == generation else { return .failure(.stale) }
        guard BridgeMessage.validText(text) else { return .failure(.rejected("翻訳できないテキストです")) }
        guard let cfg = config() else { return .failure(.notConfigured) }
        let (ratio, unit) = prefs()
        let key = CacheKey(server: cfg.baseURL.absoluteString, text: text, ratioMilli: Int((ratio * 1000).rounded()), unit: unit)
        if let hit = cached(key) { return .success(hit) }
        if let r = breakerRemaining() { return .failure(.breakerOpen(r)) }
        if Task.isCancelled { return .failure(.cancelled) }

        guard await acquire(gen: gen) else { return .failure(gen != generation ? .stale : .cancelled) }
        defer { release() }
        // State may have changed while waiting for the slot.
        guard gen == generation else { return .failure(.stale) }
        if let hit = cached(key) { return .success(hit) }
        if let r = breakerRemaining() { return .failure(.breakerOpen(r)) }
        guard requestsInGeneration < options.maxRequestsPerGeneration else { return .failure(.limitReached) }
        requestsInGeneration += 1

        guard let body = try? JSONEncoder().encode(Payload(text: text, ratio: ratio, unit: unit.rawValue)) else {
            return .failure(.rejected("リクエストを作成できませんでした"))
        }
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        if let t = cfg.token, !t.isEmpty { headers["X-Mazemaze-Token"] = t }
        let request = HTTPRequest(url: cfg.baseURL.appendingPathComponent("api/translate"), method: "POST",
                                  headers: headers, body: body, timeout: options.requestTimeout)

        var attempts = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                return .failure(gen != generation ? .stale : .cancelled)
            } catch let e as URLError {
                if e.code == .cancelled { return .failure(gen != generation ? .stale : .cancelled) }
                noteFailure()
                return .failure(e.code == .timedOut ? .timeout : .unreachable)
            } catch {
                noteFailure()
                return .failure(.unreachable)
            }

            switch response.status {
            case 200:
                switch APIDecoding.segments(from: response.body, requestText: text) {
                case .success(let segs):
                    noteSuccess()
                    store(key, segs)            // cached even if the page has moved on
                    return gen == generation ? .success(segs) : .failure(.stale)
                case .failure:
                    return .failure(.invalidResponse)      // a bad answer is not evidence the server is down
                }
            case 401:
                return .failure(.unauthorized)
            case 429:
                guard gen == generation else { return .failure(.stale) }
                attempts += 1
                if attempts > options.maxRetriesOn429 { return .failure(.busy) }
                let wait = min(max(Double(response.headers["retry-after"] ?? "") ?? 5, 1), 15)
                var waited = 0.0
                while waited < wait {
                    let step = min(0.5, wait - waited)
                    do { try await clock.sleep(seconds: step) } catch { return .failure(gen != generation ? .stale : .cancelled) }
                    waited += step
                    if gen != generation { return .failure(.stale) }
                }
                continue
            case 400, 403, 411, 413, 415, 422:
                return .failure(.rejected(Self.serverMessage(response.body) ?? "サーバーが要求を受け付けませんでした"))
            default:
                noteFailure()
                return .failure(.server(Self.serverMessage(response.body) ?? "翻訳サーバーでエラーが起きました"))
            }
        }
    }

    static func serverMessage(_ data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(APIDecoding.ErrorBody.self, from: data),
              let m = body.error?.message, !m.isEmpty else { return nil }
        return String(m.prefix(200))
    }
}
