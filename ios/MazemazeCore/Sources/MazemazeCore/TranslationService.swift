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

/// The answer to a word / phrase lookup (a card made by the local model).
public enum DefinitionOutcome: Equatable, Sendable {
    case success(DefinitionCard)
    case more(DefinitionMore)            // the second step (an example, expressions / points, synonyms)
    case failure(TranslationFailure)
}

public enum TranslationFailure: Equatable, Sendable {
    case stale, cancelled, notConfigured, unauthorized, busy, unreachable, timeout, invalidResponse, limitReached, pinMismatch, certificateUntrusted
    case rejected(String), server(String), breakerOpen(Int)
    /// The on-device engine cannot run (not supported, not enabled, language pack missing) / failed this time.
    case deviceUnavailable(String), deviceFailed(String)

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
        case .pinMismatch: return "pin_mismatch"
        case .certificateUntrusted: return "certificate_untrusted"
        case .rejected: return "rejected"
        case .server: return "server"
        case .breakerOpen: return "paused"
        case .deviceUnavailable: return "device_unavailable"
        case .deviceFailed: return "device_failed"
        }
    }

    /// The Mac could not be used because of the connection (not because of a wrong token / certificate, which must
    /// never be hidden behind a fallback): only then may the iPhone's own engine take over.
    public var allowsDeviceFallback: Bool {
        switch self {
        case .unreachable, .timeout, .busy, .breakerOpen, .notConfigured: return true
        default: return false
        }
    }

    /// Short Japanese status for the toolbar / settings. Never contains page text or the token.
    public var message: String {
        switch self {
        case .stale: return "ページが切り替わりました"
        case .cancelled: return "中断されました"
        case .notConfigured: return "翻訳サーバーが未設定です（設定で URL を入力）"
        case .unauthorized: return "トークンが違います。Mac の QR をカメラで読み取り直すか、設定を確認してください"
        case .busy: return "Mac が他の翻訳を処理中です。空き次第、自動で続きます"
        case .unreachable: return "Mac に接続できません。Mac で run_lan.sh が動いているか、同じ Wi-Fi か（家の外では iPhone の Tailscale がオンか）、iPhone の設定 > Mazemaze > ローカルネットワークが許可されているか確認してください（Mac のスリープ中も繋がりません）"
        case .timeout: return "Mac の応答が遅すぎます。しばらくして、ページを開き直してください"
        case .invalidResponse: return "翻訳サーバーの応答を読み取れませんでした"
        case .limitReached: return "このページの翻訳回数の上限に達しました。ページを再読み込みすると続きます"
        case .certificateUntrusted: return "暗号化接続（https）の証明書を確認できません。手入力では、Mac の自己署名の証明書を確認できません。Mac に表示された QR を iPhone の「カメラ」で読み取るか、ペアリング文字列を貼り付けてください。"
        case .pinMismatch: return "Mac の証明書が、ペアリングしたときと違います。別の機器になりすまされている可能性があります。信頼できる場合は、Mac に表示された QR でもう一度ペアリングしてください。"
        case .rejected(let m), .server(let m): return m
        case .breakerOpen(let s): return "翻訳サーバーのエラーが続いたため、約 \(s) 秒間停止します"
        case .deviceUnavailable(let m), .deviceFailed(let m): return m
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
        public var cacheCapacity = 1000
        public var maxRetriesOn429 = 6
        public var requestTimeout: TimeInterval = 200
        public var breakerThreshold = 3
        public var breakerCooldown: TimeInterval = 30
        public var maxRequestsPerGeneration = 600
        /// A lookup in the background (a saved word's meaning) only starts after this long without any translation.
        public var backgroundIdle: TimeInterval = 15
        public init() {}
    }

    struct CacheKey: Hashable { let server: String; let text: String; let ratioMilli: Int; let unit: TranslationUnit }
    struct Waiter { let id: UUID; let scope: Int; let gen: Int; let cont: CheckedContinuation<Bool, Never> }
    struct Payload: Encodable { let text: String; let ratio: Double; let unit: String }

    private let transport: HTTPTransport
    private let config: @Sendable () -> ServerConfig?
    private let prefs: @Sendable () -> (ratio: Double, unit: TranslationUnit)
    private let clock: ServiceClock
    private let options: Options
    private let resolver: EndpointResolver?
    private let engines: DeviceEngineProvider?
    private let enginePrefs: @Sendable () -> EnginePrefs

    /// Each browser tab is a scope with its own page generation, so one tab navigating never makes
    /// another tab's answers stale. Scope 0 is the default (single-page use and the tests).
    private var generations: [Int: Int] = [:]
    private var requestsInScope: [Int: Int] = [:]
    private var activeScope = 0
    public var generation: Int { generations[0, default: 0] }
    public func generation(of scope: Int) -> Int { generations[scope, default: 0] }
    private var lastServerSuccess: TimeInterval?
    /// What went wrong last (error code / HTTP status; never page text). Shown to help diagnose.
    public private(set) var lastErrorDetail: String?
    private var busy = false
    private var waiters: [Waiter] = []
    private var cache: [CacheKey: [TranslatedSegment]] = [:]
    private var cacheOrder: [CacheKey] = []
    private var consecutiveFailures = 0
    private var breakerOpenUntil: TimeInterval?

    public init(transport: HTTPTransport,
                config: @escaping @Sendable () -> ServerConfig?,
                prefs: @escaping @Sendable () -> (ratio: Double, unit: TranslationUnit),
                clock: ServiceClock = SystemClock(),
                options: Options = Options(),
                resolver: EndpointResolver? = nil,
                engines: DeviceEngineProvider? = nil,
                enginePrefs: @escaping @Sendable () -> EnginePrefs = { EnginePrefs() }) {
        self.transport = transport; self.config = config; self.prefs = prefs; self.clock = clock; self.options = options; self.resolver = resolver
        self.engines = engines; self.enginePrefs = enginePrefs
    }

    // MARK: generation
    @discardableResult
    public func bumpGeneration(scope: Int = 0) -> Int {
        generations[scope, default: 0] += 1
        requestsInScope[scope] = 0
        let mine = waiters.filter { $0.scope == scope }
        waiters.removeAll { $0.scope == scope }
        for w in mine { w.cont.resume(returning: false) }
        return generations[scope, default: 0]
    }

    /// The tab on screen: when the server frees up, its waiting requests go first.
    public func setActiveScope(_ scope: Int) { activeScope = scope }

    /// A closed tab: drop its state and anything it still waits for.
    public func removeScope(_ scope: Int) {
        bumpGeneration(scope: scope)           // the bumped generation stays, so a late reply can never match again
        requestsInScope[scope] = nil
    }

    private func bumpAll() {
        for scope in Set(generations.keys).union([0]) { bumpGeneration(scope: scope) }
    }

    /// Server URL / token / ratio changed: nothing cached for the old settings may be reused.
    public func configurationChanged() {
        forgetMacReachability()
        cache.removeAll(); cacheOrder.removeAll()
        consecutiveFailures = 0; breakerOpenUntil = nil
        bumpAll()
    }

    /// Forget past failures (breaker, last error) and move to a new generation.
    public func clearFailures() {
        forgetMacReachability()
        consecutiveFailures = 0; breakerOpenUntil = nil; lastErrorDetail = nil
        bumpAll()
    }

    public var cachedCount: Int { cache.count }
    public var isPaused: Bool { if let u = breakerOpenUntil { return clock.now() < u } else { return false } }

    // MARK: serialization
    private func acquire(scope: Int, gen: Int) async -> Bool {
        if gen != generation(of: scope) { return false }
        if !busy { busy = true; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { cont.resume(returning: false); return }
                waiters.append(Waiter(id: id, scope: scope, gen: gen, cont: cont))
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
        // Drop requests whose page has moved on, then give the slot to the tab on screen first.
        var live: [Waiter] = []
        for w in waiters {
            if w.gen == generation(of: w.scope) { live.append(w) } else { w.cont.resume(returning: false) }
        }
        waiters = live
        guard !waiters.isEmpty else { busy = false; return }
        // A person is waiting for a lookup card: it goes first, then the tab on screen.
        // Order: a lookup the person waits for, the tab on screen, any other tab, and last the background lookups.
        let index = waiters.firstIndex(where: { $0.scope == Self.lookupScope })
            ?? waiters.firstIndex(where: { $0.scope == activeScope })
            ?? waiters.firstIndex(where: { $0.scope != Self.backgroundScope })
            ?? 0
        let w = waiters.remove(at: index)
        w.cont.resume(returning: true)          // hand the slot over
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

    // MARK: lookup (word / phrase cards)
    /// The queue scope of lookups. They share the single slot to the Mac with translation but go first.
    static let lookupScope = -1
    /// Background lookups (the meaning of a saved word) wait for a quiet moment and always go last.
    static let backgroundScope = -2
    private var lastTranslateActivity: TimeInterval?
    private var defineCache: [String: DefinitionOutcome] = [:]
    private var defineOrder: [String] = []

    /// Ask the Mac for a card. The person is waiting, so it jumps the queue and is patient with a busy server.
    /// Results are kept in memory only (the dictionary stores the ones the person saves).
    public func define(_ request: LookupRequest, more: Bool = false, sense: String = "", background: Bool = false) async -> DefinitionOutcome {
        let p = enginePrefs()
        if p.meaning.runsOnDevice { return await defineOnDevice(request, more: more, sense: sense, background: background) }
        if p.fallbackToDevice {
            switch await macState() {
            case .unreachable: return await defineOnDevice(request, more: more, sense: sense, background: background)
            case .refused(let f): return .failure(f)          // a certificate problem is shown, never hidden behind the iPhone's engine
            case .reachable: break
            }
        }
        let outcome = await defineViaMac(request, more: more, sense: sense, background: background)
        if p.fallbackToDevice, case .failure(let f) = outcome, f.allowsDeviceFallback, !Task.isCancelled {
            forgetMacReachability()
            return await defineOnDevice(request, more: more, sense: sense, background: background)
        }
        return outcome
    }

    func defineViaMac(_ request: LookupRequest, more: Bool, sense: String, background: Bool) async -> DefinitionOutcome {
        guard let cfg = config() else { return .failure(.notConfigured) }
        let key = cfg.baseURL.absoluteString + "|" + request.id + "|" + (more ? "more:" + sense : "basic")
        if let hit = defineCache[key] { return hit }
        if Task.isCancelled { return .failure(.cancelled) }
        let scope = background ? Self.backgroundScope : Self.lookupScope
        if background {
            // Reading comes first: wait until no translation has been asked for (or running) for a while.
            while busy || (lastTranslateActivity.map { clock.now() - $0 < options.backgroundIdle } ?? false) {
                do { try await clock.sleep(seconds: 2) } catch { return .failure(.cancelled) }
                if Task.isCancelled { return .failure(.cancelled) }
            }
        }
        let gen = generation(of: scope)
        guard await acquire(scope: scope, gen: gen) else { return .failure(Task.isCancelled ? .cancelled : .stale) }
        defer { release() }
        guard gen == generation(of: scope) else { return .failure(.stale) }
        guard let cfg = config() else { return .failure(.notConfigured) }          // the settings may have changed while waiting

        struct Body: Encodable { let kind: String; let term: String; let context_en: String; let context_ja: String; let detail: String; let sense: String }
        guard let body = try? JSONEncoder().encode(Body(kind: request.kind.rawValue, term: request.term, context_en: request.contextEnglish, context_ja: request.contextJapanese,
                                                        detail: more ? "more" : "basic", sense: String(sense.unicodeScalars.prefix(60)).replacingOccurrences(of: "\u{0}", with: ""))) else {
            return .failure(.rejected("リクエストを作成できませんでした"))
        }
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        if let t = cfg.token, !t.isEmpty { headers["X-Mazemaze-Token"] = t }
        let http = HTTPRequest(url: await baseURL(for: cfg).appendingPathComponent("api/define"), method: "POST",
                               headers: headers, body: body, timeout: min(options.requestTimeout, 100))
        var attempts = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await transport.send(http)
            } catch is PinMismatchError {
                await resolver?.invalidate()
                return .failure(.pinMismatch)
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch let e as URLError {
                if e.code == .cancelled { return .failure(.cancelled) }
                if ConnectionChecker.isCertificateError(e) { return .failure(.certificateUntrusted) }
                lastErrorDetail = "通信エラー \(e.code.rawValue)"
                await resolver?.invalidate()
                return .failure(e.code == .timedOut ? .timeout : .unreachable)
            } catch {
                return .failure(.unreachable)
            }
            switch response.status {
            case 200:
                let outcome: DefinitionOutcome
                if more {
                    guard let m = DefinitionMore.decode(serverResponse: response.body) else { return .failure(.invalidResponse) }
                    outcome = .more(m)
                } else {
                    guard let card = DefinitionCard.decode(serverResponse: response.body) else { return .failure(.invalidResponse) }
                    outcome = .success(card.settingMaker(DefinitionCard.makerMac))
                }
                lastServerSuccess = clock.now()
                defineCache[key] = outcome
                defineOrder.removeAll { $0 == key }; defineOrder.append(key)
                if defineOrder.count > 200, let oldest = defineOrder.first { defineOrder.removeFirst(); defineCache[oldest] = nil }
                return outcome
            case 401:
                return .failure(.unauthorized)
            case 429:
                attempts += 1
                if attempts > (background ? 3 : 12) { return .failure(.busy) }       // a person waits about a minute; the background gives up sooner
                let wait = min(max(Double(response.headers["retry-after"] ?? "") ?? 3, 1), 6)
                var waited = 0.0
                while waited < wait {
                    let step = min(0.5, wait - waited)
                    do { try await clock.sleep(seconds: step) } catch { return .failure(.cancelled) }
                    waited += step
                }
                continue
            case 404:
                // The Mac is still running a server started before word lookup existed.
                return .failure(.server("Mac のサーバーが古いようです。Mac のターミナルで run_lan.sh を止めて（Ctrl+C）、もう一度起動してください"))
            case 400, 403, 411, 413, 415, 422:
                return .failure(.rejected(Self.serverMessage(response.body) ?? "サーバーが要求を受け付けませんでした"))
            default:
                lastErrorDetail = "HTTP \(response.status)"
                return .failure(.server(Self.serverMessage(response.body) ?? "意味を調べられませんでした"))
            }
        }
    }

    // MARK: translate
    public func translate(scope: Int = 0, gen: Int, text: String) async -> TranslationOutcome {
        let p = enginePrefs()
        if p.translation.runsOnDevice { return await translateOnDevice(p.translation, scope: scope, gen: gen, text: text) }
        let fallback: TranslationEngineKind = p.deviceTranslation.runsOnDevice ? p.deviceTranslation : .appleTranslation
        if p.fallbackToDevice {
            switch await macState() {
            case .unreachable: return await translateOnDevice(fallback, scope: scope, gen: gen, text: text)
            case .refused(let f): return .failure(f)          // a certificate problem is shown, never hidden behind the iPhone's engine
            case .reachable: break
            }
        }
        let outcome = await translateViaMac(scope: scope, gen: gen, text: text)
        if p.fallbackToDevice, case .failure(let f) = outcome, f.allowsDeviceFallback, !Task.isCancelled {
            forgetMacReachability()
            return await translateOnDevice(fallback, scope: scope, gen: gen, text: text)
        }
        return outcome
    }

    func translateViaMac(scope: Int, gen: Int, text: String) async -> TranslationOutcome {
        lastTranslateActivity = clock.now()
        defer { lastTranslateActivity = clock.now() }
        guard gen == generation(of: scope) else { return .failure(.stale) }
        guard BridgeMessage.validText(text) else { return .failure(.rejected("翻訳できないテキストです")) }
        guard let cfg = config() else { return .failure(.notConfigured) }
        let (ratio, unit) = prefs()
        let key = CacheKey(server: cfg.baseURL.absoluteString, text: text, ratioMilli: Int((ratio * 1000).rounded()), unit: unit)
        if let hit = cached(key) { return .success(hit) }
        if let r = breakerRemaining() { return .failure(.breakerOpen(r)) }
        if Task.isCancelled { return .failure(.cancelled) }

        guard await acquire(scope: scope, gen: gen) else { return .failure(gen != generation(of: scope) ? .stale : .cancelled) }
        defer { release() }
        // State may have changed while waiting for the slot.
        guard gen == generation(of: scope) else { return .failure(.stale) }
        if let hit = cached(key) { return .success(hit) }
        if let r = breakerRemaining() { return .failure(.breakerOpen(r)) }
        guard requestsInScope[scope, default: 0] < options.maxRequestsPerGeneration else { return .failure(.limitReached) }
        requestsInScope[scope, default: 0] += 1
        lastErrorDetail = nil      // only this request's cause may be shown

        guard let body = try? JSONEncoder().encode(Payload(text: text, ratio: ratio, unit: unit.rawValue)) else {
            return .failure(.rejected("リクエストを作成できませんでした"))
        }
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        if let t = cfg.token, !t.isEmpty { headers["X-Mazemaze-Token"] = t }
        let base = await baseURL(for: cfg)
        let request = HTTPRequest(url: base.appendingPathComponent("api/translate"), method: "POST",
                                  headers: headers, body: body, timeout: options.requestTimeout)

        var attempts = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is PinMismatchError {
                await resolver?.invalidate()
                return .failure(.pinMismatch)            // not a connection problem: never retried, never counted
            } catch is CancellationError {
                return .failure(gen != generation(of: scope) ? .stale : .cancelled)
            } catch let e as URLError {
                if e.code == .cancelled { return .failure(gen != generation(of: scope) ? .stale : .cancelled) }
                if ConnectionChecker.isCertificateError(e) { return .failure(.certificateUntrusted) }
                lastErrorDetail = "通信エラー \(e.code.rawValue)"
                await resolver?.invalidate()
                noteFailure()
                return .failure(e.code == .timedOut ? .timeout : .unreachable)
            } catch {
                lastErrorDetail = "通信エラー"
                noteFailure()
                return .failure(.unreachable)
            }

            switch response.status {
            case 200:
                switch APIDecoding.segments(from: response.body, requestText: text) {
                case .success(let segs):
                    lastErrorDetail = nil
                    lastServerSuccess = clock.now()
                    noteSuccess()
                    store(key, segs)            // cached even if the page has moved on
                    return gen == generation(of: scope) ? .success(segs) : .failure(.stale)
                case .failure:
                    lastErrorDetail = "応答形式エラー"
                    return .failure(.invalidResponse)      // a bad answer is not evidence the server is down
                }
            case 401:
                return .failure(.unauthorized)
            case 429:
                guard gen == generation(of: scope) else { return .failure(.stale) }
                attempts += 1
                if attempts > options.maxRetriesOn429 { return .failure(.busy) }
                let wait = min(max(Double(response.headers["retry-after"] ?? "") ?? 5, 1), 15)
                var waited = 0.0
                while waited < wait {
                    let step = min(0.5, wait - waited)
                    do { try await clock.sleep(seconds: step) } catch { return .failure(gen != generation(of: scope) ? .stale : .cancelled) }
                    waited += step
                    if gen != generation(of: scope) { return .failure(.stale) }
                }
                continue
            case 400, 403, 411, 413, 415, 422:
                return .failure(.rejected(Self.serverMessage(response.body) ?? "サーバーが要求を受け付けませんでした"))
            default:
                lastErrorDetail = "HTTP \(response.status)"
                noteFailure()
                return .failure(.server(Self.serverMessage(response.body) ?? "翻訳サーバーでエラーが起きました"))
            }
        }
    }

    /// Wake the model on the Mac (loading it takes 5-20 s) unless the server answered recently.
    /// It goes through the same single queue as translations, so nothing is requested twice at once;
    /// failures are ignored (the real requests report their own errors). Returns true if it asked.
    @discardableResult
    public func warmupIfStale(staleAfter: TimeInterval = 20 * 60) async -> Bool {
        let p = enginePrefs()
        if p.translation.runsOnDevice { return false }                      // the Mac is not used: nothing to wake
        if let last = lastServerSuccess, clock.now() - last < staleAfter { return false }
        guard let cfg = config(), breakerRemaining() == nil else { return false }
        if p.fallbackToDevice { guard case .reachable = await macState() else { return false } }
        guard await acquire(scope: activeScope, gen: generation(of: activeScope)) else { return false }
        defer { release() }
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        if let t = cfg.token, !t.isEmpty { headers["X-Mazemaze-Token"] = t }
        let request = HTTPRequest(url: await baseURL(for: cfg).appendingPathComponent("api/warmup"), method: "POST",
                                  headers: headers, body: Data("{}".utf8), timeout: 25)     // a warm-up must not hold the queue for minutes
        if let response = try? await transport.send(request), response.status == 200 { lastServerSuccess = clock.now() }
        return true
    }

    // MARK: the iPhone's own engines
    enum MacState: Equatable { case reachable, unreachable, refused(TranslationFailure) }
    private var macProbe: (state: MacState, at: TimeInterval)?
    private var macProbeTask: Task<MacState, Never>?
    private var macEpoch = 0

    /// Forget what we knew about the Mac (it failed, or the settings changed). A probe that is still running belongs to the
    /// old situation: it is detached and its answer is not kept.
    func forgetMacReachability() { macProbe = nil; lastServerSuccess = nil; macProbeTask = nil; macEpoch += 1 }

    /// With a fallback configured, ask the Mac a quick question before a long request, so an unreachable Mac is
    /// noticed in seconds (not after the request timeout) and the iPhone's engine can take over. Remembered briefly,
    /// and shared by requests that ask at the same time. A different certificate is reported as such (`.refused`).
    func macState() async -> MacState {
        guard let cfg = config() else { return .unreachable }
        if let last = lastServerSuccess, clock.now() - last < 60 { return .reachable }
        if let p = macProbe, clock.now() - p.at < (p.state == .reachable ? 60 : 10) { return p.state }
        if let running = macProbeTask { return await running.value }
        let epoch = macEpoch
        // The quick question must really go out: the resolver's own memory of an answering address (120 s) may be older than the
        // Mac's last words.
        await resolver?.invalidate()
        let task = Task<MacState, Never> { [resolver, transport] in
            if let resolver {
                if await resolver.check(cfg) != nil { return .reachable }
                let probes = await resolver.lastProbes.map(\.outcome)
                if probes.contains(.pinMismatch) { return .refused(.pinMismatch) }
                if probes.contains(.certificateError) { return .refused(.certificateUntrusted) }
                return .unreachable
            }
            let request = HTTPRequest(url: cfg.baseURL.appendingPathComponent("api/status"), method: "GET", headers: ["Accept": "application/json"], timeout: 3)
            do {
                let r = try await transport.send(request)
                return EndpointResolver.looksLikeMazemaze(r) ? .reachable : .unreachable
            } catch is PinMismatchError { return .refused(.pinMismatch) }
            catch let e as URLError where ConnectionChecker.isCertificateError(e) { return .refused(.certificateUntrusted) }
            catch { return .unreachable }
        }
        macProbeTask = task
        let state = await task.value
        if epoch == macEpoch { macProbeTask = nil; macProbe = (state, clock.now()) }          // not if the settings changed meanwhile
        return state
    }

    private func translateOnDevice(_ kind: TranslationEngineKind, scope: Int, gen: Int, text: String) async -> TranslationOutcome {
        lastTranslateActivity = clock.now()
        defer { lastTranslateActivity = clock.now() }
        guard gen == generation(of: scope) else { return .failure(.stale) }
        guard BridgeMessage.validText(text) else { return .failure(.rejected("翻訳できないテキストです")) }
        guard let engine = engines?.translationEngine(kind) else {
            return .failure(.deviceUnavailable("この iPhone では「\(kind.title)」を使えません。設定で翻訳の方法を確認してください"))
        }
        let (ratio, unit) = prefs()
        let key = CacheKey(server: "device:" + engine.identifier, text: text, ratioMilli: Int((ratio * 1000).rounded()), unit: unit)
        if let hit = cached(key) { return .success(hit) }
        if Task.isCancelled { return .failure(.cancelled) }

        guard await acquire(scope: scope, gen: gen) else { return .failure(gen != generation(of: scope) ? .stale : .cancelled) }
        defer { release() }
        guard gen == generation(of: scope) else { return .failure(.stale) }
        if let hit = cached(key) { return .success(hit) }
        guard requestsInScope[scope, default: 0] < options.maxRequestsPerGeneration else { return .failure(.limitReached) }
        requestsInScope[scope, default: 0] += 1
        lastErrorDetail = nil

        do {
            let result = try await OnDeviceTranslator.translate(text: text, ratio: ratio, unit: unit, engine: engine)
            if result.failedBatches == 0 { store(key, result.segments) }        // a partly Japanese result (a batch failed) is not kept: the next try may do better
            return gen == generation(of: scope) ? .success(result.segments) : .failure(.stale)
        } catch let e as EngineError {
            switch e {
            case .unavailable(let m): lastErrorDetail = "iPhone: 利用不可"; return .failure(.deviceUnavailable(m))
            case .failed(let m): lastErrorDetail = "iPhone: 失敗"; return .failure(.deviceFailed(m + "（原文はそのままです。もう一度お試しください。続く場合は、設定で翻訳の方法を切り替えてください）"))
            }
        } catch is CancellationError {
            return .failure(gen != generation(of: scope) ? .stale : .cancelled)
        } catch {
            lastErrorDetail = "iPhone: 内部エラー"
            return .failure(.deviceFailed("この iPhone での翻訳に失敗しました。原文はそのままです"))
        }
    }

    private func defineOnDevice(_ request: LookupRequest, more: Bool, sense: String, background: Bool) async -> DefinitionOutcome {
        guard let engine = engines?.definitionEngine() else {
            return .failure(.deviceUnavailable("この iPhone では単語の意味を作れません。設定で意味の作り方を確認してください"))
        }
        let key = "device:" + engine.identifier + "|" + request.id + "|" + (more ? "more:" + sense : "basic")
        if let hit = defineCache[key] { return hit }
        if Task.isCancelled { return .failure(.cancelled) }
        let scope = background ? Self.backgroundScope : Self.lookupScope
        if background {
            while busy || (lastTranslateActivity.map { clock.now() - $0 < options.backgroundIdle } ?? false) {
                do { try await clock.sleep(seconds: 2) } catch { return .failure(.cancelled) }
                if Task.isCancelled { return .failure(.cancelled) }
            }
        }
        let gen = generation(of: scope)
        guard await acquire(scope: scope, gen: gen) else { return .failure(Task.isCancelled ? .cancelled : .stale) }
        defer { release() }
        guard gen == generation(of: scope) else { return .failure(.stale) }

        let cleanSense = String(sense.unicodeScalars.prefix(60)).replacingOccurrences(of: "\u{0}", with: "")
        let detail: DefinitionDetail = more ? .more : .basic
        do {
            let raw = try await engine.answer(kind: request.kind, detail: detail, term: request.term, contextEnglish: request.contextEnglish,
                                              contextJapanese: request.contextJapanese, sense: cleanSense)
            let content = OnDeviceDefinition.refine(kind: request.kind, detail: detail, term: request.term, contextEnglish: request.contextEnglish, content: raw)
            guard let body = OnDeviceDefinition.serverResponse(kind: request.kind, detail: detail, content: content, contextJapanese: request.contextJapanese) else {
                return .failure(.deviceFailed("この iPhone のモデルの答えを読み取れませんでした。もう一度お試しください"))
            }
            let outcome: DefinitionOutcome
            if more {
                guard let m = DefinitionMore.decode(serverResponse: body) else { return .failure(.deviceFailed("この iPhone のモデルの答えを読み取れませんでした。もう一度お試しください")) }
                outcome = .more(m)
            } else {
                guard let card = DefinitionCard.decode(serverResponse: body) else { return .failure(.deviceFailed("この iPhone のモデルの答えを読み取れませんでした。もう一度お試しください")) }
                outcome = .success(card.settingMaker(DefinitionCard.makerDevice))
            }
            defineCache[key] = outcome
            defineOrder.removeAll { $0 == key }; defineOrder.append(key)
            if defineOrder.count > 200, let oldest = defineOrder.first { defineOrder.removeFirst(); defineCache[oldest] = nil }
            return outcome
        } catch let e as EngineError {
            switch e {
            case .unavailable(let m): return .failure(.deviceUnavailable(m))
            case .failed(let m): return .failure(.deviceFailed(m))
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.deviceFailed("この iPhone での意味の作成に失敗しました"))
        }
    }

    private func baseURL(for cfg: ServerConfig) async -> URL {
        guard let resolver else { return cfg.baseURL }
        return await resolver.resolve(cfg)
    }

    static func serverMessage(_ data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(APIDecoding.ErrorBody.self, from: data),
              let m = body.error?.message, !m.isEmpty else { return nil }
        return String(m.prefix(200))
    }
}
