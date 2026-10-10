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

/// The answer to a word / phrase lookup (a card made by the on-device model).
public enum DefinitionOutcome: Equatable, Sendable {
    case success(DefinitionCard)
    case more(DefinitionMore)            // the second step (an example, expressions / points, synonyms)
    case failure(TranslationFailure)
}

public enum TranslationFailure: Equatable, Sendable {
    case stale, cancelled, limitReached
    case rejected(String)
    /// The engine cannot run (not supported, not enabled, language data missing) / failed this time. The text is Japanese,
    /// says what to do next, and never contains page text.
    case unavailable(String), failed(String)

    /// The code the page script sees. `not_configured` stops translating on the page until the settings are fixed;
    /// `server` is retried a few times per text, then the text is left alone.
    public var code: String {
        switch self {
        case .stale: return "stale"
        case .cancelled: return "cancelled"
        case .limitReached: return "limit_reached"
        case .rejected: return "rejected"
        case .unavailable: return "not_configured"
        case .failed: return "server"
        }
    }

    /// Short Japanese status for the toolbar / settings. Never contains page text.
    public var message: String {
        switch self {
        case .stale: return "ページが切り替わりました"
        case .cancelled: return "中断されました"
        case .limitReached: return "このページの翻訳回数の上限に達しました。ページを再読み込みすると続きます"
        case .rejected(let m), .unavailable(let m), .failed(let m): return m
        }
    }
}

public enum TranslationOutcome: Equatable, Sendable {
    case success([TranslatedSegment])
    case failure(TranslationFailure)

    /// A plist/JSON-compatible dictionary for the page-side script. Only the pieces the script needs.
    public func bridgePayload() -> [String: Any] {
        switch self {
        case .success(let segs):
            return ["ok": true, "segments": segs.map { ["kind": $0.kind.rawValue, "source": $0.source, "display": $0.display] }]
        case .failure(let f):
            return ["ok": false, "error": f.code, "message": f.message]
        }
    }
}

/// Runs every translation and lookup on the iPhone: the app chooses the spans, an engine (Apple Translation / Apple
/// Intelligence) proposes English, the app validates it and rebuilds the text from slices of itself. Requests go one at a time
/// (the engines are heavy), requests from an old page generation are dropped, results are cached in memory only, and a lookup
/// the person waits for goes before page translation.
public actor TranslationService {
    public struct Options: Sendable {
        public var cacheCapacity = 1000
        public var maxRequestsPerGeneration = 600
        /// A lookup in the background (a saved word's meaning) only starts after this long without any translation.
        public var backgroundIdle: TimeInterval = 15
        public init() {}
    }

    struct CacheKey: Hashable { let engine: String; let text: String; let ratioMilli: Int; let unit: TranslationUnit }
    struct Waiter { let id: UUID; let scope: Int; let gen: Int; let cont: CheckedContinuation<Bool, Never> }

    private let engines: DeviceEngineProvider
    private let engine: @Sendable () -> TranslationEngineKind
    private let prefs: @Sendable () -> (ratio: Double, unit: TranslationUnit)
    private let clock: ServiceClock
    private let options: Options

    /// Each browser tab is a scope with its own page generation, so one tab navigating never makes
    /// another tab's answers stale. Scope 0 is the default (single-page use and the tests).
    private var generations: [Int: Int] = [:]
    private var requestsInScope: [Int: Int] = [:]
    private var activeScope = 0
    public var generation: Int { generations[0, default: 0] }
    public func generation(of scope: Int) -> Int { generations[scope, default: 0] }
    private var busy = false
    private var waiters: [Waiter] = []
    private var cache: [CacheKey: [TranslatedSegment]] = [:]
    private var cacheOrder: [CacheKey] = []

    public init(engines: DeviceEngineProvider,
                engine: @escaping @Sendable () -> TranslationEngineKind,
                prefs: @escaping @Sendable () -> (ratio: Double, unit: TranslationUnit),
                clock: ServiceClock = SystemClock(),
                options: Options = Options()) {
        self.engines = engines; self.engine = engine; self.prefs = prefs; self.clock = clock; self.options = options
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

    /// The tab on screen: when the engine frees up, its waiting requests go first.
    public func setActiveScope(_ scope: Int) { activeScope = scope }

    /// A closed tab: drop its state and anything it still waits for.
    public func removeScope(_ scope: Int) {
        bumpGeneration(scope: scope)           // the bumped generation stays, so a late reply can never match again
        requestsInScope[scope] = nil
    }

    private func bumpAll() {
        for scope in Set(generations.keys).union([0]) { bumpGeneration(scope: scope) }
    }

    /// The engine or the ratio / unit changed: nothing cached for the old settings may be reused.
    public func configurationChanged() {
        cache.removeAll(); cacheOrder.removeAll()
        bumpAll()
    }

    /// Move to a new generation (the engine may be ready now).
    public func clearFailures() {
        bumpAll()
    }

    public var cachedCount: Int { cache.count }

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

    // MARK: lookup (word / phrase cards)
    /// The queue scope of lookups. They share the single slot with translation but go first.
    static let lookupScope = -1
    /// Background lookups (the meaning of a saved word) wait for a quiet moment and always go last.
    static let backgroundScope = -2
    private var lastTranslateActivity: TimeInterval?
    private var defineCache: [String: DefinitionOutcome] = [:]
    private var defineOrder: [String] = []

    /// Make a card. The person is waiting, so it jumps the queue. Results are kept in memory only (the dictionary stores the
    /// ones the person saves).
    public func define(_ request: LookupRequest, more: Bool = false, sense: String = "", background: Bool = false) async -> DefinitionOutcome {
        guard let definer = engines.definitionEngine() else {
            return .failure(.unavailable("この iPhone では単語の意味を作れません。Apple Intelligence に対応した iPhone で、設定アプリ > Apple Intelligence と Siri をオンにしてください"))
        }
        let key = definer.identifier + "|" + request.id + "|" + (more ? "more:" + sense : "basic")
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

        let cleanSense = String(sense.unicodeScalars.prefix(60)).replacingOccurrences(of: "\u{0}", with: "")
        let detail: DefinitionDetail = more ? .more : .basic
        let unusable = "iPhone のモデルの答えを読み取れませんでした。もう一度お試しください"
        do {
            let raw = try await definer.answer(kind: request.kind, detail: detail, term: request.term, contextEnglish: request.contextEnglish,
                                               contextJapanese: request.contextJapanese, sense: cleanSense)
            let content = OnDeviceDefinition.refine(kind: request.kind, detail: detail, term: request.term, contextEnglish: request.contextEnglish, content: raw)
            guard let body = OnDeviceDefinition.serverResponse(kind: request.kind, detail: detail, content: content, contextJapanese: request.contextJapanese) else {
                return .failure(.failed(unusable))
            }
            let outcome: DefinitionOutcome
            if more {
                guard let m = DefinitionMore.decode(serverResponse: body) else { return .failure(.failed(unusable)) }
                outcome = .more(m)
            } else {
                guard let card = DefinitionCard.decode(serverResponse: body) else { return .failure(.failed(unusable)) }
                outcome = .success(card)
            }
            defineCache[key] = outcome
            defineOrder.removeAll { $0 == key }; defineOrder.append(key)
            if defineOrder.count > 200, let oldest = defineOrder.first { defineOrder.removeFirst(); defineCache[oldest] = nil }
            return outcome
        } catch let e as EngineError {
            switch e {
            case .unavailable(let m): return .failure(.unavailable(m))
            case .failed(let m): return .failure(.failed(m))
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed("この iPhone での意味の作成に失敗しました"))
        }
    }

    // MARK: translate
    public func translate(scope: Int = 0, gen: Int, text: String) async -> TranslationOutcome {
        lastTranslateActivity = clock.now()
        defer { lastTranslateActivity = clock.now() }
        guard gen == generation(of: scope) else { return .failure(.stale) }
        guard BridgeMessage.validText(text) else { return .failure(.rejected("翻訳できないテキストです")) }
        let kind = engine()
        guard let translator = engines.translationEngine(kind) else {
            return .failure(.unavailable("この iPhone では「\(kind.title)」を使えません。設定で翻訳の方法を確認してください"))
        }
        let (ratio, unit) = prefs()
        let key = CacheKey(engine: translator.identifier, text: text, ratioMilli: Int((ratio * 1000).rounded()), unit: unit)
        if let hit = cached(key) { return .success(hit) }
        if Task.isCancelled { return .failure(.cancelled) }

        guard await acquire(scope: scope, gen: gen) else { return .failure(gen != generation(of: scope) ? .stale : .cancelled) }
        defer { release() }
        guard gen == generation(of: scope) else { return .failure(.stale) }
        if let hit = cached(key) { return .success(hit) }
        guard requestsInScope[scope, default: 0] < options.maxRequestsPerGeneration else { return .failure(.limitReached) }
        requestsInScope[scope, default: 0] += 1

        do {
            let result = try await OnDeviceTranslator.translate(text: text, ratio: ratio, unit: unit, engine: translator)
            if result.failedBatches == 0 { store(key, result.segments) }        // a partly Japanese result (a batch failed) is not kept: the next try may do better
            return gen == generation(of: scope) ? .success(result.segments) : .failure(.stale)
        } catch let e as EngineError {
            switch e {
            case .unavailable(let m): return .failure(.unavailable(m))
            case .failed(let m): return .failure(.failed(m + "（原文はそのままです。もう一度お試しください。続く場合は、設定で翻訳の方法を切り替えてください）"))
            }
        } catch is CancellationError {
            return .failure(gen != generation(of: scope) ? .stale : .cancelled)
        } catch {
            return .failure(.failed("この iPhone での翻訳に失敗しました。原文はそのままです"))
        }
    }
}
