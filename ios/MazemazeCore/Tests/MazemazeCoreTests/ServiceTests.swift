import XCTest
@testable import MazemazeCore

// MARK: - helpers

/// Scripted transport. `handler` decides each response; `gate` can hold a request open.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    private var active = 0
    private(set) var maxActive = 0
    var handler: @Sendable (HTTPRequest, Int) async throws -> HTTPResponse
    var gates: [String: AsyncGate] = [:]   // text -> gate

    init(handler: @escaping @Sendable (HTTPRequest, Int) async throws -> HTTPResponse) { self.handler = handler }

    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock(); requests.append(request); active += 1; maxActive = max(maxActive, active); let n = requests.count; lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if let text = Self.text(of: request), let gate = gates[text] { await gate.wait() }
        return try await handler(request, n)
    }

    static func text(of r: HTTPRequest) -> String? {
        guard let b = r.body, let o = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return nil }
        return o["text"] as? String
    }
}

actor AsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; let w = waiters; waiters = []; w.forEach { $0.resume() } }
}

final class ManualClock: ServiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    private(set) var sleeps: [Double] = []
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
    func sleep(seconds: Double) async throws { lock.lock(); sleeps.append(seconds); t += seconds; lock.unlock(); await Task.yield() }
}

func okResponse(for request: HTTPRequest, english: String = "Hello") -> HTTPResponse {
    let text = MockTransport.text(of: request) ?? ""
    let body: [String: Any] = ["segments": [["kind": "en", "source": text, "translation": english + ".", "display": english]]]
    return HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
}

/// A reply that looks like the Mazemaze server's own 401.
func serverUnauthorized() -> HTTPResponse {
    HTTPResponse(status: 401, body: try! JSONSerialization.data(withJSONObject: ["error": ["code": "token_required", "message": "x"]]))
}

func jsonResponse(_ status: Int, message: String? = nil, headers: [String: String] = [:]) -> HTTPResponse {
    let body = message.map { try! JSONSerialization.data(withJSONObject: ["error": ["code": "x", "message": $0]]) } ?? Data("{}".utf8)
    return HTTPResponse(status: status, headers: headers, body: body)
}

final class PrefsBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: (ratio: Double, unit: TranslationUnit) = (0.3, .phrase)
    var value: (ratio: Double, unit: TranslationUnit) { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

func makeService(_ transport: MockTransport, clock: ManualClock = ManualClock(), prefs: PrefsBox = PrefsBox(),
                 token: String? = "secret-token", options: TranslationService.Options = .init()) -> TranslationService {
    let cfg = ServerConfig(baseURL: URL(string: "http://192.168.0.19:8000")!, token: token)
    return TranslationService(transport: transport, config: { cfg }, prefs: { prefs.value }, clock: clock, options: options)
}

// MARK: - tests

final class TranslationServiceTests: XCTestCase {
    func testRequestShape() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t)
        let out = await s.translate(gen: 0, text: "日本語のテキストです")
        XCTAssertEqual(out, .success([TranslatedSegment(kind: .en, source: "日本語のテキストです", display: "Hello")]))
        let r = t.requests[0]
        XCTAssertEqual(r.url.absoluteString, "http://192.168.0.19:8000/api/translate")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["X-Mazemaze-Token"], "secret-token")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertNil(r.headers["Origin"])
        XCTAssertGreaterThanOrEqual(r.timeout, 200)
        let o = try! JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
        XCTAssertEqual(Set(o.keys), ["text", "ratio", "unit"])
        XCTAssertEqual(o["unit"] as? String, "phrase")
    }

    func testSerializesConcurrentRequests() async {
        let t = MockTransport { r, _ in try await Task.sleep(nanoseconds: 15_000_000); return okResponse(for: r) }
        let s = makeService(t)
        await withTaskGroup(of: TranslationOutcome.self) { g in
            for i in 0..<6 { g.addTask { await s.translate(gen: 0, text: "テキスト番号 \(i) です") } }
            for await o in g { if case .failure = o { XCTFail("unexpected failure") } }
        }
        XCTAssertEqual(t.count, 6)
        XCTAssertEqual(t.maxActive, 1)
    }

    func testCacheAndKeyDimensions() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let prefs = PrefsBox()
        let s = makeService(t, prefs: prefs)
        _ = await s.translate(gen: 0, text: "同じテキストです")
        _ = await s.translate(gen: 0, text: "同じテキストです")
        XCTAssertEqual(t.count, 1)
        prefs.value = (0.5, .phrase); _ = await s.translate(gen: 0, text: "同じテキストです")
        prefs.value = (0.5, .sentence); _ = await s.translate(gen: 0, text: "同じテキストです")
        XCTAssertEqual(t.count, 3)
        // delimiter-like characters in text cannot collide with another key
        _ = await s.translate(gen: 0, text: "a|0.3|phrase です")
        _ = await s.translate(gen: 0, text: "a です")
        XCTAssertEqual(t.count, 5)
        await s.configurationChanged()
        let g = await s.generation
        _ = await s.translate(gen: g, text: "同じテキストです")
        XCTAssertEqual(t.count, 6)
    }

    func testCacheEvictsOldest() async {
        var o = TranslationService.Options(); o.cacheCapacity = 2
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t, options: o)
        for x in ["一つ目のテキスト", "二つ目のテキスト", "三つ目のテキスト"] { _ = await s.translate(gen: 0, text: x) }
        let cached = await s.cachedCount
        XCTAssertEqual(cached, 2)
        _ = await s.translate(gen: 0, text: "一つ目のテキスト")   // evicted -> new request
        XCTAssertEqual(t.count, 4)
    }

    func testFailuresAreNotCached() async {
        let t = MockTransport { r, n in n == 1 ? jsonResponse(500) : okResponse(for: r) }
        let s = makeService(t)
        let a = await s.translate(gen: 0, text: "失敗のあとのテキスト")
        XCTAssertEqual(a, .failure(.server("翻訳サーバーでエラーが起きました")))
        let b = await s.translate(gen: 0, text: "失敗のあとのテキスト")
        guard case .success = b else { return XCTFail() }
    }

    func testStaleGenerationInFlightFinishesAndIsCachedButReportedStale() async {
        let gate = AsyncGate()
        let t = MockTransport { r, _ in okResponse(for: r) }
        t.gates["待たされるテキスト"] = gate
        let s = makeService(t)
        let task = Task { await s.translate(gen: 0, text: "待たされるテキスト") }
        while t.count == 0 { await Task.yield() }
        let newGen = await s.bumpGeneration()
        await gate.release()
        let out = await task.value
        XCTAssertEqual(out, .failure(.stale))            // the page has moved on
        let again = await s.translate(gen: newGen, text: "待たされるテキスト")
        guard case .success = again else { return XCTFail("result should have been cached") }
        XCTAssertEqual(t.count, 1)                       // and was not requested again
    }

    func testWaitingRequestsBecomeStaleAfterBump() async {
        let gate = AsyncGate()
        let t = MockTransport { r, _ in okResponse(for: r) }
        t.gates["先頭のテキストです"] = gate
        let s = makeService(t)
        let a = Task { await s.translate(gen: 0, text: "先頭のテキストです") }
        while t.count == 0 { await Task.yield() }
        let b = Task { await s.translate(gen: 0, text: "待っているテキスト") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await s.bumpGeneration()
        let bo = await b.value
        XCTAssertEqual(bo, .failure(.stale))
        await gate.release()
        _ = await a.value
        XCTAssertEqual(t.count, 1)                       // B never reached the server
        let g = await s.generation
        let c = await s.translate(gen: g, text: "新しい世代のテキスト")
        guard case .success = c else { return XCTFail("slot must have been released") }
    }

    func testCancelledWaiterDoesNotLeakTheSlot() async {
        let gate = AsyncGate()
        let t = MockTransport { r, _ in okResponse(for: r) }
        t.gates["先頭のテキストです"] = gate
        let s = makeService(t)
        let a = Task { await s.translate(gen: 0, text: "先頭のテキストです") }
        while t.count == 0 { await Task.yield() }
        let b = Task { await s.translate(gen: 0, text: "キャンセルされるテキスト") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        b.cancel()
        let bo = await b.value
        XCTAssertEqual(bo, .failure(.cancelled))
        await gate.release()
        _ = await a.value
        let c = await s.translate(gen: 0, text: "そのあとのテキスト")
        guard case .success = c else { return XCTFail() }
        XCTAssertEqual(t.count, 2)
    }

    func test429RetriesWithRetryAfter() async {
        let clock = ManualClock()
        let t = MockTransport { r, n in n < 3 ? jsonResponse(429, headers: ["retry-after": "2"]) : okResponse(for: r) }
        let s = makeService(t, clock: clock)
        let out = await s.translate(gen: 0, text: "混雑しているテキスト")
        guard case .success = out else { return XCTFail("\(out)") }
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(clock.sleeps.reduce(0, +), 4, accuracy: 0.01)
    }

    func test429RetryAfterIsClampedAndExhausts() async {
        let clock = ManualClock()
        var o = TranslationService.Options(); o.maxRetriesOn429 = 2
        for header in ["abc", "0", "-5", "99999", ""] {
            let t = MockTransport { _, _ in jsonResponse(429, headers: header.isEmpty ? [:] : ["retry-after": header]) }
            let s = makeService(t, clock: clock, options: o)
            let out = await s.translate(gen: 0, text: "ずっと混雑しているテキスト")
            XCTAssertEqual(out, .failure(.busy), header)
            XCTAssertEqual(t.count, 3)
        }
        XCTAssertTrue(clock.sleeps.allSatisfy { $0 > 0 && $0 <= 0.5 + 1e-9 })   // sliced; total per wait is within 1...15
    }

    func test429DoesNotTripBreakerAndStaleStopsRetry() async {
        let t = MockTransport { _, _ in jsonResponse(429) }
        var o = TranslationService.Options(); o.maxRetriesOn429 = 1
        let s = makeService(t, options: o)
        for i in 0..<4 { let out = await s.translate(gen: 0, text: "混雑テキスト番号\(i)です"); XCTAssertEqual(out, .failure(.busy)) }
        let paused = await s.isPaused
        XCTAssertFalse(paused)
    }

    func testBreakerOpensAfterConsecutiveFailuresAndRecovers() async {
        let clock = ManualClock()
        let fail = LockedFlag(true)
        let t = MockTransport { r, _ in fail.value ? jsonResponse(503, message: "Ollama に接続できません") : okResponse(for: r) }
        let s = makeService(t, clock: clock)
        for i in 0..<3 { _ = await s.translate(gen: 0, text: "失敗が続くテキスト\(i)") }
        XCTAssertEqual(t.count, 3)
        let open = await s.translate(gen: 0, text: "停止中のテキストです")
        guard case .failure(.breakerOpen(let secs)) = open else { return XCTFail("\(open)") }
        XCTAssertGreaterThan(secs, 0)
        XCTAssertEqual(t.count, 3)                      // no request while open
        clock.advance(31); fail.value = false
        let trial = await s.translate(gen: 0, text: "再開後のテキストです")
        guard case .success = trial else { return XCTFail("\(trial)") }
        let paused = await s.isPaused
        XCTAssertFalse(paused)
    }

    func testHalfOpenFailureReopens() async {
        let clock = ManualClock()
        let t = MockTransport { _, _ in jsonResponse(502) }
        let s = makeService(t, clock: clock)
        for i in 0..<3 { _ = await s.translate(gen: 0, text: "失敗が続くテキスト\(i)") }
        clock.advance(31)
        _ = await s.translate(gen: 0, text: "試行のテキストです")
        XCTAssertEqual(t.count, 4)
        let again = await s.translate(gen: 0, text: "また停止のテキスト")
        guard case .failure(.breakerOpen) = again else { return XCTFail("\(again)") }
    }

    func testClientErrorsDoNotTripBreaker() async {
        for status in [401, 400, 403, 413, 415, 422] {
            let t = MockTransport { _, _ in jsonResponse(status, message: "メッセージ") }
            let s = makeService(t)
            for i in 0..<5 { _ = await s.translate(gen: 0, text: "クライアントエラー\(status)の\(i)") }
            XCTAssertEqual(t.count, 5, "status \(status)")
            let paused = await s.isPaused
            XCTAssertFalse(paused)
        }
        let t = MockTransport { _, _ in jsonResponse(401) }
        let out = await makeService(t).translate(gen: 0, text: "認証が必要なテキスト")
        XCTAssertEqual(out, .failure(.unauthorized))
    }

    func testInvalidResponsesDoNotTripTheBreaker() async {
        let t = MockTransport { _, _ in HTTPResponse(status: 200, body: Data("{\"nope\":1}".utf8)) }
        let s = makeService(t)
        for i in 0..<5 { _ = await s.translate(gen: 0, text: "壊れた応答のテキスト\(i)です") }
        XCTAssertEqual(t.count, 5)
        let paused = await s.isPaused
        XCTAssertFalse(paused)
    }

    func testInvalidResponsesAreDiscarded() async {
        let bad: [[String: Any]] = [
            ["segments": [["kind": "en", "source": "違うテキスト", "translation": "x", "display": "x"]]],            // source mismatch
            ["segments": [["kind": "ja", "source": "対象のテキストです", "translation": NSNull(), "display": "changed"]]], // ja altered
            ["segments": [["kind": "en", "source": "対象のテキストです", "translation": "x", "display": "a\nb"]]],       // newline
            ["segments": [["kind": "en", "source": "対象のテキストです", "translation": "x", "display": "  "]]],         // blank
            ["segments": [["kind": "zz", "source": "対象のテキストです", "translation": "x", "display": "x"]]],          // unknown kind
            ["nope": 1],
        ]
        for b in bad {
            let t = MockTransport { _, _ in HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: b)) }
            let s = makeService(t)
            let out = await s.translate(gen: 0, text: "対象のテキストです")
            XCTAssertEqual(out, .failure(.invalidResponse), "\(b)")
            let n = await s.cachedCount
            XCTAssertEqual(n, 0)
        }
    }

    func testUnicodeNormalizationDifferenceIsAMismatch() async {
        let nfd = "か\u{3099}き"           // か + combining dakuten
        let nfc = "が" + "き"
        let t = MockTransport { _, _ in
            HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: ["segments": [["kind": "ja", "source": nfc, "translation": NSNull(), "display": nfc]]])) }
        let out = await makeService(t).translate(gen: 0, text: nfd + "のテキスト" )
        XCTAssertEqual(out, .failure(.invalidResponse))
    }

    func testTransportErrorsMap() async {
        let cases: [(Error, TranslationFailure)] = [(URLError(.timedOut), .timeout), (URLError(.cannotConnectToHost), .unreachable),
                                                    (URLError(.notConnectedToInternet), .unreachable), (URLError(.cancelled), .cancelled)]
        for (err, expected) in cases {
            let t = MockTransport { _, _ in throw err }
            let out = await makeService(t).translate(gen: 0, text: "エラーのテキストです")
            XCTAssertEqual(out, .failure(expected))
        }
    }

    func testNotConfiguredAndBadText() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = TranslationService(transport: t, config: { nil }, prefs: { (0.3, .phrase) })
        let out = await s.translate(gen: 0, text: "設定がないテキスト")
        XCTAssertEqual(out, .failure(.notConfigured))
        let s2 = makeService(t)
        let bad = await s2.translate(gen: 0, text: "   ")
        guard case .failure(.rejected) = bad else { return XCTFail() }
        XCTAssertEqual(t.count, 0)
    }

    func testPerGenerationLimit() async {
        var o = TranslationService.Options(); o.maxRequestsPerGeneration = 3
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t, options: o)
        for i in 0..<3 { _ = await s.translate(gen: 0, text: "制限のテキスト番号\(i)") }
        let out = await s.translate(gen: 0, text: "制限を超えるテキスト")
        XCTAssertEqual(out, .failure(.limitReached))
        let g = await s.bumpGeneration()
        let next = await s.translate(gen: g, text: "次の世代のテキスト")
        guard case .success = next else { return XCTFail() }
    }

    func testBridgePayloadHasNoSecretsOrURLs() {
        let ok = TranslationOutcome.success([TranslatedSegment(kind: .en, source: "原文", display: "Source")]).bridgePayload()
        XCTAssertEqual(ok["ok"] as? Bool, true)
        let fail = TranslationOutcome.failure(.unauthorized).bridgePayload()
        XCTAssertEqual(fail["ok"] as? Bool, false)
        XCTAssertFalse("\(fail)".contains("secret"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(ok) && JSONSerialization.isValidJSONObject(fail))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}

final class TransportAndSettingsTests: XCTestCase {
    func testRedirectsAreNeverFollowed() {
        let transport = URLSessionTransport()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://192.168.0.1/")!)
        let response = HTTPURLResponse(url: URL(string: "http://192.168.0.1/")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://8.8.8.8/"])!
        var followed: URLRequest? = URLRequest(url: URL(string: "http://placeholder/")!)
        transport.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "http://8.8.8.8/")!)) { followed = $0 }
        XCTAssertNil(followed)
    }

    func testSettingsKeepTokenOutOfUserDefaults() throws {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        store.serverURLString = "http://192.168.0.19:8000"
        try store.setToken("  abc123  ")
        XCTAssertEqual(store.token, "abc123")
        XCTAssertEqual(secrets.token(), "abc123")
        let dump = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined()
        XCTAssertFalse(dump.contains("abc123"))
        XCTAssertEqual(store.serverConfig()?.baseURL.absoluteString, "http://192.168.0.19:8000")
        store.serverURLString = "http://8.8.8.8:8000"
        XCTAssertNil(store.serverConfig())          // public hosts never become a config
        try store.setToken(nil)
        XCTAssertNil(store.token)
    }

    func testPreferencesAreClampedAndHostsNormalized() {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertEqual(store.ratio, 0.3); XCTAssertEqual(store.unit, .phrase); XCTAssertTrue(store.translationEnabled)
        store.ratio = 5; XCTAssertEqual(store.ratio, 0.7)
        store.ratio = -1; XCTAssertEqual(store.ratio, 0.1)
        XCTAssertEqual(store.allowedHosts, SitePolicy.defaultAllowedHosts)
        store.allowedHosts = ["Example.JP", "com", "192.168.0.1", "news.example.co.jp"]
        XCTAssertEqual(store.allowedHosts, ["example.jp", "news.example.co.jp"])
    }

    func testConnectionCheckerMessages() async {
        let cfg = ServerConfig(baseURL: URL(string: "http://192.168.0.19:8000")!, token: "t")
        func report(_ status: Int, _ json: [String: Any]? = nil) async -> ConnectionReport {
            let t = MockTransport { _, _ in HTTPResponse(status: status, body: json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()) }
            return await ConnectionChecker.check(config: cfg, transport: t)
        }
        let good = await report(200, ["model": "qwen3.5:9b", "ollama_reachable": true, "model_installed": true, "model_metadata_ok": true, "busy": false])
        XCTAssertEqual(good.state, .ok); XCTAssertEqual(good.model, "qwen3.5:9b")
        let noOllama = await report(200, ["model": "qwen3.5:9b", "ollama_reachable": false, "model_installed": false, "model_metadata_ok": false, "busy": false])
        XCTAssertEqual(noOllama.state, .warning)
        let noModel = await report(200, ["model": "qwen3.5:9b", "ollama_reachable": true, "model_installed": false, "model_metadata_ok": false, "busy": false])
        XCTAssertEqual(noModel.state, .warning)
        for status in [401, 400, 403, 500] { let r = await report(status); XCTAssertEqual(r.state, .failed); XCTAssertFalse(r.message.contains("t\n")) }
        let garbage = await report(200)
        XCTAssertEqual(garbage.state, .failed)
        let none = await ConnectionChecker.check(config: nil, transport: MockTransport { _, _ in HTTPResponse(status: 200) })
        XCTAssertEqual(none.state, .failed)
        let down = await ConnectionChecker.check(config: cfg, transport: MockTransport { _, _ in throw URLError(.cannotConnectToHost) })
        XCTAssertEqual(down.state, .failed)
        let t = MockTransport { _, _ in HTTPResponse(status: 401) }
        _ = await ConnectionChecker.check(config: cfg, transport: t)
        XCTAssertEqual(t.requests[0].headers["X-Mazemaze-Token"], "t")
        XCTAssertEqual(t.requests[0].url.path, "/api/status")
    }
}

final class WarmupTests: XCTestCase {
    func testWarmupSendsAnAuthenticatedBodylessRequestOnceThenSkipsWhileFresh() async {
        let t = MockTransport { r, _ in
            r.url.path == "/api/warmup" ? HTTPResponse(status: 200, body: Data("{\"ok\":true}".utf8)) : okResponse(for: r) }
        let clock = ManualClock()
        let s = makeService(t, clock: clock)
        let asked = await s.warmupIfStale()
        XCTAssertTrue(asked)
        XCTAssertEqual(t.requests[0].url.path, "/api/warmup")
        XCTAssertEqual(t.requests[0].method, "POST")
        XCTAssertEqual(t.requests[0].headers["X-Mazemaze-Token"], "secret-token")
        XCTAssertEqual(String(data: t.requests[0].body ?? Data(), encoding: .utf8), "{}")      // no page text
        let again = await s.warmupIfStale()
        XCTAssertFalse(again)                                   // answered a moment ago
        clock.advance(21 * 60)
        let stale = await s.warmupIfStale()
        XCTAssertTrue(stale)
        XCTAssertEqual(t.count, 2)
    }

    func testARecentTranslationCountsAsFresh() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t)
        _ = await s.translate(gen: 0, text: "最近翻訳したテキストです")
        let asked = await s.warmupIfStale()
        XCTAssertFalse(asked)
        XCTAssertEqual(t.count, 1)
    }

    func testWarmupSharesTheSingleQueueAndIgnoresFailures() async {
        let gate = AsyncGate()
        let t = MockTransport { r, _ in
            if r.url.path == "/api/warmup" { await gate.wait(); return HTTPResponse(status: 503) }
            return okResponse(for: r) }
        let s = makeService(t)
        let w = Task { await s.warmupIfStale() }
        while t.count == 0 { await Task.yield() }
        let tr = Task { await s.translate(gen: 0, text: "ウォームアップの後ろで待つテキスト") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(t.count, 1)                              // the translation waits for the slot
        await gate.release()
        _ = await w.value
        let out = await tr.value
        guard case .success = out else { return XCTFail("\(out)") }
        XCTAssertEqual(t.maxActive, 1)
        let paused = await s.isPaused
        XCTAssertFalse(paused)                                  // a failed warm-up never trips the breaker
    }

    func testNoConfigNoWarmup() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = TranslationService(transport: t, config: { nil }, prefs: { (0.3, .phrase) })
        let asked = await s.warmupIfStale()
        XCTAssertFalse(asked)
        XCTAssertEqual(t.count, 0)
    }
}

final class ScopeTests: XCTestCase {
    func testTabsHaveIndependentGenerations() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t)
        let a = await s.bumpGeneration(scope: 1)
        _ = await s.bumpGeneration(scope: 2)
        _ = await s.bumpGeneration(scope: 2)
        let g2 = await s.generation(of: 2)
        let g1 = await s.generation(of: 1)
        XCTAssertEqual(a, 1); XCTAssertEqual(g1, 1); XCTAssertEqual(g2, 2)
        let ok = await s.translate(scope: 1, gen: 1, text: "タブ一のテキストです")
        guard case .success = ok else { return XCTFail() }
        let stale = await s.translate(scope: 2, gen: 1, text: "タブ二の古い世代のテキスト")
        XCTAssertEqual(stale, .failure(.stale))
        _ = await s.bumpGeneration(scope: 1)       // tab 1 navigates
        let still = await s.translate(scope: 2, gen: 2, text: "タブ二は影響を受けないテキスト")
        guard case .success = still else { return XCTFail("tab 2 must not go stale when tab 1 navigates") }
    }

    func testTheTabOnScreenGetsTheServerFirst() async {
        let gate = AsyncGate()
        let order = OrderBox()
        let t = MockTransport { r, _ in order.add(MockTransport.text(of: r) ?? ""); return okResponse(for: r) }
        t.gates["先頭の要求です"] = gate
        let s = makeService(t)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        await s.setActiveScope(2)
        let head = Task { await s.translate(scope: 1, gen: 1, text: "先頭の要求です") }
        while t.count == 0 { await Task.yield() }
        let bg = Task { await s.translate(scope: 1, gen: 1, text: "背景タブの要求です") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let fg = Task { await s.translate(scope: 2, gen: 1, text: "前面タブの要求です") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await gate.release()
        _ = await head.value; _ = await bg.value; _ = await fg.value
        XCTAssertEqual(order.all, ["先頭の要求です", "前面タブの要求です", "背景タブの要求です"])
    }

    func testNoStarvation() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        await s.setActiveScope(2)
        async let bg = s.translate(scope: 1, gen: 1, text: "背景だけの要求ですよ")
        async let f1 = s.translate(scope: 2, gen: 1, text: "前面の要求その一です")
        async let f2 = s.translate(scope: 2, gen: 1, text: "前面の要求その二です")
        let results = await [bg, f1, f2]
        for r in results { guard case .success = r else { return XCTFail("\(r)") } }
    }

    func testClosingATabDropsItsWaitersAndState() async {
        let gate = AsyncGate()
        let t = MockTransport { r, _ in okResponse(for: r) }
        t.gates["占有する要求です"] = gate
        let s = makeService(t)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        let hold = Task { await s.translate(scope: 1, gen: 1, text: "占有する要求です") }
        while t.count == 0 { await Task.yield() }
        let waiting = Task { await s.translate(scope: 2, gen: 1, text: "閉じられるタブの要求です") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await s.removeScope(2)
        let out = await waiting.value
        XCTAssertEqual(out, .failure(.stale))
        await gate.release()
        _ = await hold.value
        XCTAssertEqual(t.count, 1)
        let g = await s.generation(of: 2)
        XCTAssertGreaterThan(g, 0)          // the bumped generation stays: a late reply can never match again
    }

    func testConfigurationChangeStalesEveryTab() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        await s.configurationChanged()
        let a = await s.translate(scope: 1, gen: 1, text: "設定変更のあとのテキストＡ")
        let b = await s.translate(scope: 2, gen: 1, text: "設定変更のあとのテキストＢ")
        XCTAssertEqual(a, .failure(.stale)); XCTAssertEqual(b, .failure(.stale))
    }

    func testRequestLimitIsPerTab() async {
        var o = TranslationService.Options(); o.maxRequestsPerGeneration = 2
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = makeService(t, options: o)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        for i in 0..<2 { _ = await s.translate(scope: 1, gen: 1, text: "タブ一の要求その\(i)です") }
        let over = await s.translate(scope: 1, gen: 1, text: "タブ一の上限超えの要求")
        XCTAssertEqual(over, .failure(.limitReached))
        let other = await s.translate(scope: 2, gen: 1, text: "タブ二はまだ使える要求")
        guard case .success = other else { return XCTFail() }
    }
}

final class OrderBox: @unchecked Sendable {
    private let l = NSLock(); private var items: [String] = []
    func add(_ s: String) { l.lock(); items.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return items }
}

final class ResolverAndPinServiceTests: XCTestCase {
    func cfgService(_ t: HTTPTransport, resolver: EndpointResolver?, fallback: Bool = true, clock: ManualClock = ManualClock()) -> TranslationService {
        let cfg = ServerConfig(baseURL: URL(string: "http://mac.local:8000")!, token: "secret-token",
                               fallbackURL: fallback ? URL(string: "http://192.168.0.19:8000")! : nil)
        return TranslationService(transport: t, config: { cfg }, prefs: { (0.3, .phrase) }, clock: clock, resolver: resolver)
    }

    func testFallsBackToTheIPAddressWhenTheNameCannotBeFound_andNeverSendsTheTokenWhileProbing() async {
        let t = MockTransport { r, _ in
            if r.url.host == "mac.local" { throw URLError(.cannotFindHost) }
            if r.url.path == "/api/status" { return serverUnauthorized() }
            return okResponse(for: r)
        }
        let s = cfgService(t, resolver: EndpointResolver(transport: t))
        let out = await s.translate(gen: 0, text: "名前解決に失敗するテキスト")
        guard case .success = out else { return XCTFail("\(out)") }
        let probes = t.requests.filter { $0.url.path == "/api/status" }
        XCTAssertEqual(probes.map { $0.url.host }, ["mac.local", "192.168.0.19"])
        XCTAssertTrue(probes.allSatisfy { $0.headers["X-Mazemaze-Token"] == nil })        // probes carry no token
        let translate = t.requests.last!
        XCTAssertEqual(translate.url.host, "192.168.0.19")
        XCTAssertEqual(translate.headers["X-Mazemaze-Token"], "secret-token")
    }

    func testThePreferredNameIsUsedWhenItAnswers_andTheChoiceIsRemembered() async {
        let t = MockTransport { r, _ in r.url.path == "/api/status" ? serverUnauthorized() : okResponse(for: r) }
        let s = cfgService(t, resolver: EndpointResolver(transport: t))
        _ = await s.translate(gen: 0, text: "最初のテキストです")
        _ = await s.translate(gen: 0, text: "二つ目のテキストです")
        XCTAssertEqual(t.requests.filter { $0.url.path == "/api/status" }.count, 1)       // probed once, then remembered
        XCTAssertTrue(t.requests.filter { $0.url.path == "/api/translate" }.allSatisfy { $0.url.host == "mac.local" })
    }

    func testAHostThatDoesNotAnswerLikeTheServerIsNotChosen() async {
        let t = MockTransport { r, _ in
            if r.url.host == "mac.local" { return HTTPResponse(status: 404) }        // something else lives at this name
            return r.url.path == "/api/status" ? serverUnauthorized() : okResponse(for: r)
        }
        let resolver = EndpointResolver(transport: t)
        let cfg = ServerConfig(baseURL: URL(string: "http://mac.local:8000")!, token: "t", fallbackURL: URL(string: "http://192.168.0.19:8000")!)
        let chosen = await resolver.resolve(cfg)
        XCTAssertEqual(chosen.host, "192.168.0.19")
    }

    func testAnotherDeviceThatJustSaysUnauthorizedIsNotTheServer() async {
        let t = MockTransport { r, _ in
            if r.url.host == "mac.local" { throw URLError(.cannotFindHost) }
            return HTTPResponse(status: 401, body: Data("Unauthorized".utf8))          // a router / NAS / printer
        }
        let cfg = ServerConfig(baseURL: URL(string: "https://mac.local:8000")!, token: "t", fallbackURL: URL(string: "https://192.168.0.19:8000")!)
        let chosen = await EndpointResolver(transport: t).resolve(cfg)
        XCTAssertEqual(chosen.host, "mac.local")                  // nothing qualified: the primary is kept, the token never goes elsewhere
        XCTAssertTrue(t.requests.allSatisfy { $0.headers["X-Mazemaze-Token"] == nil })
    }

    func testNobodyAnsweringIsRememberedBrieflyInsteadOfWaitingForEveryRequest() async {
        let t = MockTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let clock = ManualClock()
        let resolver = EndpointResolver(transport: t, clock: clock)
        let cfg = ServerConfig(baseURL: URL(string: "http://mac.local:8000")!, token: "t", fallbackURL: URL(string: "http://192.168.0.19:8000")!)
        _ = await resolver.resolve(cfg)
        let probesFirst = t.count
        _ = await resolver.resolve(cfg); _ = await resolver.resolve(cfg)
        XCTAssertEqual(t.count, probesFirst)                      // no new probes within the next few seconds
        clock.advance(11)
        _ = await resolver.resolve(cfg)
        XCTAssertGreaterThan(t.count, probesFirst)
    }

    func testNoFallbackMeansNoProbing() async {
        let t = MockTransport { r, _ in okResponse(for: r) }
        let s = cfgService(t, resolver: EndpointResolver(transport: t), fallback: false)
        _ = await s.translate(gen: 0, text: "代替の住所がないテキスト")
        XCTAssertEqual(t.requests.filter { $0.url.path == "/api/status" }.count, 0)
    }

    func testAPinMismatchIsReportedAsSuchAndCountsAsNothing() async {
        let t = MockTransport { _, _ in throw PinMismatchError() }
        let s = cfgService(t, resolver: nil)
        for i in 0..<4 { let out = await s.translate(gen: 0, text: "証明書が違うテキスト\(i)"); XCTAssertEqual(out, .failure(.pinMismatch)) }
        XCTAssertEqual(t.count, 4)                                   // not paused by the breaker, every attempt reaches the transport
        let paused = await s.isPaused
        XCTAssertFalse(paused)
        XCTAssertTrue(TranslationFailure.pinMismatch.message.contains("証明書"))
        XCTAssertEqual(TranslationFailure.pinMismatch.code, "pin_mismatch")
    }

    func testConnectionCheckExplainsAPinMismatch() async {
        let t = MockTransport { _, _ in throw PinMismatchError() }
        let cfg = ServerConfig(baseURL: URL(string: "https://mac.local:8000")!, token: "t", pinnedFingerprint: String(repeating: "ab", count: 32))
        let report = await ConnectionChecker.check(config: cfg, transport: t)
        XCTAssertEqual(report.state, .failed)
        XCTAssertTrue(report.message.contains("証明書"))
    }
}

final class TailscaleResolverTests: XCTestCase {
    func cfg() -> ServerConfig {
        ServerConfig(baseURL: URL(string: "https://mac.local:8000")!, token: "t", fallbackURL: URL(string: "https://192.168.0.19:8000")!,
                     pinnedFingerprint: String(repeating: "ab", count: 32), tailscaleURL: URL(string: "https://yuya-4.tailb93afe.ts.net:8000")!)
    }

    func testAwayFromHomeTheTailscaleAddressIsUsed_withShortHomeProbesAndNoToken() async {
        let t = MockTransport { r, _ in
            if r.url.host == "yuya-4.tailb93afe.ts.net" { return serverUnauthorized() }
            throw URLError(.timedOut)
        }
        let chosen = await EndpointResolver(transport: t).resolve(cfg())
        XCTAssertEqual(chosen.host, "yuya-4.tailb93afe.ts.net")
        XCTAssertEqual(t.requests.map { $0.url.host }, ["mac.local", "192.168.0.19", "yuya-4.tailb93afe.ts.net"])
        XCTAssertEqual(t.requests.map { $0.timeout }, [1.5, 1.5, 6])
        XCTAssertTrue(t.requests.allSatisfy { $0.headers["X-Mazemaze-Token"] == nil })
    }

    func testAtHomeTheTailscaleAddressIsNeverProbed() async {
        let t = MockTransport { _, _ in serverUnauthorized() }
        let chosen = await EndpointResolver(transport: t).resolve(cfg())
        XCTAssertEqual(chosen.host, "mac.local")
        XCTAssertEqual(t.requests.map { $0.url.host }, ["mac.local"])
    }

    func testTheHomeIPAddressStillBeatsTailscale() async {
        let t = MockTransport { r, _ in
            if r.url.host == "mac.local" { throw URLError(.cannotFindHost) }
            return serverUnauthorized()
        }
        let chosen = await EndpointResolver(transport: t).resolve(cfg())
        XCTAssertEqual(chosen.host, "192.168.0.19")
        XCTAssertFalse(t.requests.contains { $0.url.host == "yuya-4.tailb93afe.ts.net" })
    }

    func testAnotherDeviceAtTheTailscaleAddressIsNotTheServer() async {
        let t = MockTransport { r, _ in
            if r.url.host == "yuya-4.tailb93afe.ts.net" { return HTTPResponse(status: 401, body: Data("Unauthorized".utf8)) }
            throw URLError(.timedOut)
        }
        let chosen = await EndpointResolver(transport: t).resolve(cfg())
        XCTAssertEqual(chosen.host, "mac.local")                 // nobody qualified: the primary is kept
    }

    func testAConfigWithoutTailscaleKeepsTheOldTimeouts() async {
        let t = MockTransport { _, _ in throw URLError(.timedOut) }
        let c = ServerConfig(baseURL: URL(string: "http://mac.local:8000")!, token: "t", fallbackURL: URL(string: "http://192.168.0.19:8000")!)
        _ = await EndpointResolver(transport: t).resolve(c)
        XCTAssertEqual(t.requests.map { $0.timeout }, [3, 3])
    }

    func testAPinnedTailscaleServerWithAnotherCertificateIsNotChosen() async {
        let t = MockTransport { r, _ in
            if r.url.host == "yuya-4.tailb93afe.ts.net" { throw PinMismatchError() }
            throw URLError(.timedOut)
        }
        let chosen = await EndpointResolver(transport: t).resolve(cfg())
        XCTAssertEqual(chosen.host, "mac.local")
    }
}

final class ProbeReportTests: XCTestCase {
    func cfg(tailscale: Bool = true) -> ServerConfig {
        ServerConfig(baseURL: URL(string: "https://mac.local:8000")!, token: "t", fallbackURL: URL(string: "https://192.168.0.19:8000")!,
                     pinnedFingerprint: String(repeating: "ab", count: 32), tailscaleURL: tailscale ? URL(string: "https://yuya-4.tailb93afe.ts.net:8000")! : nil)
    }

    func testTheReportNamesEveryAddressThatWasTried_withoutURLsOrTheToken() async {
        let t = MockTransport { r, _ in
            if r.url.host == "mac.local" { throw URLError(.cannotFindHost) }
            if r.url.host == "yuya-4.tailb93afe.ts.net" { throw URLError(.timedOut) }
            throw URLError(.timedOut)
        }
        let report = await ConnectionChecker.check(config: cfg(), transport: t, resolver: EndpointResolver(transport: t))
        XCTAssertEqual(report.state, .failed)
        XCTAssertTrue(report.message.contains("Mac の名前: 名前が見つからない"), report.message)
        XCTAssertTrue(report.message.contains("家の IP アドレス: 応答なし"), report.message)
        XCTAssertTrue(report.message.contains("Tailscale（外出先）: 応答なし"), report.message)
        XCTAssertFalse(report.message.contains("yuya-4.tailb93afe.ts.net") || report.message.contains("192.168.0.19") || report.message.contains("mac.local:8000"))
    }

    func testAMissingTailscaleAddressIsSaid() async {
        let t = MockTransport { _, _ in throw URLError(.timedOut) }
        let report = await ConnectionChecker.check(config: cfg(tailscale: false), transport: t, resolver: EndpointResolver(transport: t))
        XCTAssertTrue(report.message.contains("この設定には入っていません"), report.message)
    }

    func testPinMismatchAndOtherDevicesAreDistinguished() async {
        let t = MockTransport { r, _ in
            if r.url.host == "yuya-4.tailb93afe.ts.net" { throw PinMismatchError() }
            return HTTPResponse(status: 404)
        }
        let resolver = EndpointResolver(transport: t)
        _ = await resolver.resolve(cfg())
        let probes = await resolver.lastProbes
        XCTAssertEqual(probes.map { $0.outcome }, [.notMazemaze(status: 404), .notMazemaze(status: 404), .pinMismatch])
    }
}
