import XCTest
@testable import MazemazeCore

final class FakeSpanEngine: SpanTranslationEngine, @unchecked Sendable {
    let identifier: String
    private let lock = NSLock()
    private var _calls: [[SelectedSpan]] = []
    var handler: @Sendable (String, [SelectedSpan]) async throws -> [String: String]
    init(_ id: String = "fake", handler: @escaping @Sendable (String, [SelectedSpan]) async throws -> [String: String]) { identifier = id; self.handler = handler }
    var calls: [[SelectedSpan]] { lock.lock(); defer { lock.unlock() }; return _calls }
    func translate(text: String, spans: [SelectedSpan]) async throws -> [String: String] {
        lock.lock(); _calls.append(spans); lock.unlock()
        return try await handler(text, spans)
    }
}

final class FakeDefinitionEngine: DefinitionEngine, @unchecked Sendable {
    let identifier = "fake-def"
    private let lock = NSLock()
    private var _count = 0
    var handler: @Sendable (LookupKind, DefinitionDetail, String) async throws -> String
    init(handler: @escaping @Sendable (LookupKind, DefinitionDetail, String) async throws -> String) { self.handler = handler }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func answer(kind: LookupKind, detail: DefinitionDetail, term: String, contextEnglish: String, contextJapanese: String, sense: String) async throws -> String {
        lock.lock(); _count += 1; lock.unlock()
        return try await handler(kind, detail, term)
    }
}

final class FakeProvider: DeviceEngineProvider, @unchecked Sendable {
    var translators: [TranslationEngineKind: SpanTranslationEngine] = [:]
    var definer: DefinitionEngine?
    func translationEngine(_ kind: TranslationEngineKind) -> SpanTranslationEngine? { translators[kind] }
    func definitionEngine() -> DefinitionEngine? { definer }
}

final class FirstCall: @unchecked Sendable {
    private let l = NSLock(); private var seen = false
    func isFirst() -> Bool { l.lock(); defer { l.unlock() }; defer { seen = true }; return !seen }
}

final class EnginePrefsBox: @unchecked Sendable {
    private let lock = NSLock(); private var p = EnginePrefs()
    var value: EnginePrefs { get { lock.lock(); defer { lock.unlock() }; return p } set { lock.lock(); p = newValue; lock.unlock() } }
}

/// An English word for every span: "T<n>" (always valid: letters and a digit, no Japanese).
let numberedEnglish: @Sendable (String, [SelectedSpan]) async throws -> [String: String] = { _, spans in
    Dictionary(uniqueKeysWithValues: spans.map { ($0.id, "Phrase number \(String($0.id.dropFirst()))") })
}

final class OnDeviceTranslatorTests: XCTestCase {
    let text = "今日は天気がいいので、友達と一緒に新しいカフェで朝ごはんを食べた。そのあと、公園を散歩した。"

    func testReplacesOnlyTheChosenSpansAndKeepsEverythingElseExactly() async throws {
        let engine = FakeSpanEngine(handler: numberedEnglish)
        let r = try await OnDeviceTranslator.translate(text: text, ratio: 0.5, unit: .phrase, engine: engine)
        XCTAssertEqual(r.segments.map(\.source).joined(), text)
        XCTAssertGreaterThan(r.segments.filter { $0.kind == .en }.count, 0)
        for s in r.segments where s.kind == .ja { XCTAssertEqual(s.display, s.source) }
        XCTAssertEqual(r.failedBatches, 0)
    }

    func testBatchesFollowTheServerRule() {
        let spans = (1...14).map { SelectedSpan(id: "s\($0)", start: $0 * 10, end: $0 * 10 + 5, source: String(repeating: "あ", count: 5)) }
        let b = OnDeviceTranslator.batches(spans)
        XCTAssertEqual(b.map(\.count), [6, 6, 2])
        let long = (1...4).map { SelectedSpan(id: "s\($0)", start: $0 * 100, end: $0 * 100 + 60, source: String(repeating: "い", count: 60)) }
        XCTAssertEqual(OnDeviceTranslator.batches(long).map(\.count), [2, 2])          // 150 characters per call
    }

    func testAnswersThatFailValidationStayJapanese() async throws {
        let engine = FakeSpanEngine { _, spans in
            var out: [String: String] = [:]
            for (i, s) in spans.enumerated() {
                switch i % 4 {
                case 0: out[s.id] = "日本語が混ざった"          // Japanese characters
                case 1: out[s.id] = "line\nbreak"               // newline
                case 2: out[s.id] = "ＡＢＣ、ＤＥＦ"             // full-width
                default: out[s.id] = "A perfectly fine phrase"
                }
            }
            return out
        }
        let r = try await OnDeviceTranslator.translate(text: text, ratio: 0.7, unit: .phrase, engine: engine)
        XCTAssertEqual(r.segments.map(\.source).joined(), text)
        for s in r.segments where s.kind == .en { XCTAssertEqual(s.display.lowercased(), "a perfectly fine phrase") }
    }

    func testIdsThatWereNotAskedForAreIgnored() async throws {
        let engine = FakeSpanEngine { _, _ in ["s99": "Injected", "s1": "Fine words"] }
        let r = try await OnDeviceTranslator.translate(text: text, ratio: 0.5, unit: .phrase, engine: engine)
        XCTAssertFalse(r.segments.contains { $0.display.contains("Injected") })
        XCTAssertEqual(r.segments.map(\.source).joined(), text)
    }

    func testUnavailableEngineIsReportedNotSwallowed() async {
        let engine = FakeSpanEngine { _, _ in throw EngineError.unavailable("言語パックがありません") }
        do { _ = try await OnDeviceTranslator.translate(text: text, ratio: 0.5, unit: .phrase, engine: engine); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? EngineError, .unavailable("言語パックがありません")) }
    }

    func testEveryBatchFailingThrows_butSomeFailingKeepsTheRest() async throws {
        let many = (1...12).map { "今日は天気がいい\($0 % 2 == 0 ? "です" : "ね")、とても楽しかった。" }.joined()      // several batches
        let allFail = FakeSpanEngine { _, _ in throw EngineError.failed("x") }
        do { _ = try await OnDeviceTranslator.translate(text: many, ratio: 0.7, unit: .phrase, engine: allFail); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? EngineError, .failed("x")) }

        let flag = FirstCall()
        let someFail = FakeSpanEngine { t, spans in
            if flag.isFirst() { throw EngineError.failed("once") }
            return try await numberedEnglish(t, spans)
        }
        let r = try await OnDeviceTranslator.translate(text: many, ratio: 0.7, unit: .phrase, engine: someFail)
        XCTAssertEqual(r.segments.map(\.source).joined(), many)
        XCTAssertEqual(r.failedBatches, 1)
    }

    func testCancellationPropagates() async {
        let engine = FakeSpanEngine { _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return [:] }
        let task = Task { try await OnDeviceTranslator.translate(text: text, ratio: 0.5, unit: .phrase, engine: engine) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("should throw") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    /// Whatever an engine says, the Japanese outside the replaced spans comes back identical, for every text the
    /// Python reference was checked on.
    func testOriginalTextIsAlwaysRebuiltExactly_withHostileEngines() async throws {
        let hostile = FakeSpanEngine { _, spans in
            var out: [String: String] = [:]
            let pool = ["Hello.", "the weather is nice.", "", "   ", "日本語", "ok\n", "See https://evil.example now", "A", "...", "3.", "Mr. Yamada", "x@y.zz", "<b>", "[name]"]
            for (i, s) in spans.enumerated() { out[s.id] = pool[(i * 7 + s.start) % pool.count] }
            return out
        }
        var checked = 0
        for t in OnDeviceGoldenTests.golden.texts.prefix(700) where BridgeMessage.validText(t) {
            let r = try await OnDeviceTranslator.translate(text: t, ratio: 0.5, unit: .phrase, engine: hostile)
            XCTAssertEqual(Array(r.segments.map(\.source).joined().unicodeScalars), Array(t.unicodeScalars), "text \(t.debugDescription.prefix(60))")
            for s in r.segments where s.kind == .ja { XCTAssertEqual(s.display, s.source) }
            for s in r.segments where s.kind == .en { XCTAssertFalse(s.display.isEmpty); XCTAssertFalse(s.display.contains("\n")) }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 300)
    }
}

final class OnDeviceServiceTests: XCTestCase {
    let text = "今日は天気がいいので、友達と一緒に新しいカフェで朝ごはんを食べた。"

    func make(_ t: MockTransport, prefs: EnginePrefsBox, provider: FakeProvider, config: Bool = true) -> TranslationService {
        let cfg = ServerConfig(baseURL: URL(string: "http://mac.local:8000")!, token: "secret-token")
        return TranslationService(transport: t, config: { config ? cfg : nil }, prefs: { (0.5, .phrase) }, clock: ManualClock(), resolver: nil,
                                  engines: provider, enginePrefs: { prefs.value })
    }

    func testOnDeviceEngineNeverTouchesTheNetwork() async {
        let t = MockTransport { _, _ in XCTFail("the Mac must not be used"); return HTTPResponse(status: 500) }
        let box = EnginePrefsBox(); box.value.translation = .foundationModels
        let provider = FakeProvider(); let engine = FakeSpanEngine("fm", handler: numberedEnglish); provider.translators[.foundationModels] = engine
        let s = make(t, prefs: box, provider: provider)
        let out = await s.translate(gen: 0, text: text)
        guard case .success(let segs) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(segs.map(\.source).joined(), text)
        XCTAssertEqual(t.count, 0)
        let again = await s.translate(gen: 0, text: text)            // cached
        XCTAssertEqual(again, out)
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testEnginesHaveSeparateCaches() async {
        let t = MockTransport { _, _ in HTTPResponse(status: 500) }
        let box = EnginePrefsBox(); box.value.translation = .appleTranslation
        let provider = FakeProvider()
        let a = FakeSpanEngine("apple") { _, spans in Dictionary(uniqueKeysWithValues: spans.map { ($0.id, "From apple") }) }
        let f = FakeSpanEngine("fm") { _, spans in Dictionary(uniqueKeysWithValues: spans.map { ($0.id, "From model") }) }
        provider.translators = [.appleTranslation: a, .foundationModels: f]
        let s = make(t, prefs: box, provider: provider)
        let first = await s.translate(gen: 0, text: text)
        box.value.translation = .foundationModels
        let second = await s.translate(gen: 0, text: text)
        XCTAssertNotEqual(first, second)
        guard case .success(let segs) = second else { return XCTFail() }
        XCTAssertTrue(segs.contains { $0.display.lowercased().contains("from model") })
    }

    func testMissingEngineIsAnUnavailableMessage() async {
        let box = EnginePrefsBox(); box.value.translation = .foundationModels
        let s = make(MockTransport { _, _ in HTTPResponse(status: 500) }, prefs: box, provider: FakeProvider())
        let out = await s.translate(gen: 0, text: text)
        guard case .failure(.deviceUnavailable(let m)) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(m.contains("iPhone"))
    }

    func testStaleGenerationIsDropped() async {
        let box = EnginePrefsBox(); box.value.translation = .appleTranslation
        let provider = FakeProvider(); provider.translators[.appleTranslation] = FakeSpanEngine(handler: numberedEnglish)
        let s = make(MockTransport { _, _ in HTTPResponse(status: 500) }, prefs: box, provider: provider)
        _ = await s.bumpGeneration()
        let out = await s.translate(gen: 0, text: text)
        XCTAssertEqual(out, .failure(.stale))
    }

    // ---- Mac first, the iPhone when the Mac cannot be reached
    func fallbackSetup(macStatus: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) -> (TranslationService, MockTransport, FakeSpanEngine) {
        let t = MockTransport { r, _ in try await macStatus(r) }
        let box = EnginePrefsBox(); box.value.fallbackToDevice = true; box.value.deviceTranslation = .appleTranslation
        let provider = FakeProvider(); let engine = FakeSpanEngine("apple", handler: numberedEnglish); provider.translators[.appleTranslation] = engine
        return (make(t, prefs: box, provider: provider), t, engine)
    }

    func testUnreachableMacFallsBackToTheIPhone_quicklyAndWithoutSendingText() async {
        let (s, t, engine) = fallbackSetup { _ in throw URLError(.cannotConnectToHost) }
        let out = await s.translate(gen: 0, text: text)
        guard case .success = out else { return XCTFail("\(out)") }
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(t.requests.allSatisfy { $0.url.path == "/api/status" }, "only the quick reachability question went out, not the text")
        XCTAssertTrue(t.requests.allSatisfy { $0.headers["X-Mazemaze-Token"] == nil })
    }

    func testReachableMacIsUsedAndTheIPhoneEngineIsNotTouched() async {
        let (s, t, engine) = fallbackSetup { r in r.url.path == "/api/status" ? serverUnauthorized() : okResponse(for: r) }
        let out = await s.translate(gen: 0, text: text)
        guard case .success = out else { return XCTFail("\(out)") }
        XCTAssertEqual(engine.calls.count, 0)
        XCTAssertTrue(t.requests.contains { $0.url.path == "/api/translate" })
    }

    func testAWrongTokenIsNeverHiddenBehindTheFallback() async {
        let (s, _, engine) = fallbackSetup { r in
            if r.url.path == "/api/status" { return serverUnauthorized() }
            return HTTPResponse(status: 401, body: try! JSONSerialization.data(withJSONObject: ["error": ["code": "token_required", "message": "x"]]))
        }
        let out = await s.translate(gen: 0, text: text)
        XCTAssertEqual(out, .failure(.unauthorized))
        XCTAssertEqual(engine.calls.count, 0)
    }

    func testMacFailingMidwayFallsBack() async {
        let (s, _, engine) = fallbackSetup { r in
            if r.url.path == "/api/status" { return serverUnauthorized() }
            throw URLError(.timedOut)
        }
        let out = await s.translate(gen: 0, text: text)
        guard case .success = out else { return XCTFail("\(out)") }
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testADifferentCertificateIsShownNotHiddenBehindTheFallback() async {
        let (s, t, engine) = fallbackSetup { _ in throw PinMismatchError() }
        let out = await s.translate(gen: 0, text: text)
        XCTAssertEqual(out, .failure(.pinMismatch))
        XCTAssertEqual(engine.calls.count, 0)
        XCTAssertTrue(t.requests.allSatisfy { $0.headers["X-Mazemaze-Token"] == nil })
        let (s2, _, engine2) = fallbackSetup { _ in throw URLError(.serverCertificateUntrusted) }
        let out2 = await s2.translate(gen: 0, text: text)
        XCTAssertEqual(out2, .failure(.certificateUntrusted))
        XCTAssertEqual(engine2.calls.count, 0)
    }

    func testPinMismatchThroughTheResolverIsAlsoShown() async {
        let cfg = ServerConfig(baseURL: URL(string: "https://mac.local:8000")!, token: "t", fallbackURL: URL(string: "https://192.168.0.19:8000")!, pinnedFingerprint: String(repeating: "ab", count: 32))
        let t = MockTransport { r, _ in
            if r.url.host == "mac.local" { throw URLError(.cannotFindHost) }
            throw PinMismatchError()
        }
        let box = EnginePrefsBox(); box.value.fallbackToDevice = true
        let provider = FakeProvider(); let engine = FakeSpanEngine(handler: numberedEnglish); provider.translators[.appleTranslation] = engine
        let s = TranslationService(transport: t, config: { cfg }, prefs: { (0.5, .phrase) }, clock: ManualClock(), resolver: EndpointResolver(transport: t),
                                   engines: provider, enginePrefs: { box.value })
        let out = await s.translate(gen: 0, text: text)
        XCTAssertEqual(out, .failure(.pinMismatch))
        XCTAssertEqual(engine.calls.count, 0)
    }

    func testDeviceOnlyNeedsNoMacAtAll() async {
        let t = MockTransport { _, _ in XCTFail("no network"); return HTTPResponse(status: 500) }
        let box = EnginePrefsBox(); box.value.translation = .appleTranslation; box.value.meaning = .foundationModels
        let provider = FakeProvider(); provider.translators[.appleTranslation] = FakeSpanEngine(handler: numberedEnglish); provider.definer = FakeDefinitionEngine { _, _, _ in self.wordAnswer }
        let s = make(t, prefs: box, provider: provider, config: false)
        guard case .success = await s.translate(gen: 0, text: text) else { return XCTFail() }
        let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .success = await s.define(req) else { return XCTFail() }
        XCTAssertEqual(t.count, 0)
    }

    func testAPartlyFailedDeviceResultIsNotCached() async {
        let t = MockTransport { _, _ in HTTPResponse(status: 500) }
        let box = EnginePrefsBox(); box.value.translation = .appleTranslation
        let many = (1...12).map { "今日は天気がいい\($0 % 2 == 0 ? "です" : "ね")、とても楽しかった。" }.joined()
        let provider = FakeProvider()
        let first = FirstCall()
        let engine = FakeSpanEngine { t, spans in if first.isFirst() { throw EngineError.failed("once") }; return try await numberedEnglish(t, spans) }
        provider.translators[.appleTranslation] = engine
        let s = make(t, prefs: box, provider: provider)
        _ = await s.translate(gen: 0, text: many)
        let callsAfterFirst = engine.calls.count
        _ = await s.translate(gen: 0, text: many)                  // asked again: the partial result was not kept
        XCTAssertGreaterThan(engine.calls.count, callsAfterFirst)
    }

    func testConcurrentRequestsShareOneReachabilityQuestion() async {
        let gate = AsyncGate()
        let t = MockTransport { r, _ in
            if r.url.path == "/api/status" { await gate.wait(); return serverUnauthorized() }
            return okResponse(for: r)
        }
        let box = EnginePrefsBox(); box.value.fallbackToDevice = true
        let provider = FakeProvider(); provider.translators[.appleTranslation] = FakeSpanEngine(handler: numberedEnglish)
        let s = make(t, prefs: box, provider: provider)
        async let a = s.translate(gen: 0, text: text)
        async let b = s.translate(gen: 0, text: text + "。もう一文です、これも日本語です。")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        _ = await (a, b)
        XCTAssertEqual(t.requests.filter { $0.url.path == "/api/status" }.count, 1)
    }

    func testAFailureMakesTheNextRequestAskAgainInsteadOfTrustingTheOldAnswer() async {
        let up = LockedFlag(true)
        let (s, t, _) = fallbackSetup { r in
            if r.url.path == "/api/status" { if up.value { return serverUnauthorized() }; throw URLError(.cannotConnectToHost) }
            if up.value { return okResponse(for: r) }
            throw URLError(.timedOut)
        }
        guard case .success = await s.translate(gen: 0, text: text) else { return XCTFail() }
        up.value = false                                         // the Mac goes to sleep within a minute of a success
        guard case .success = await s.translate(gen: 0, text: text + "。もう一文です、これも日本語です。") else { return XCTFail() }
        let statusCount = t.requests.filter { $0.url.path == "/api/status" }.count
        guard case .success = await s.translate(gen: 0, text: text + "。さらに別の文です、これも日本語です。") else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(t.requests.filter { $0.url.path == "/api/status" }.count, statusCount, "asks again after a failure (not served from the old answer)")
        XCTAssertEqual(t.requests.filter { $0.url.path == "/api/translate" }.count, 2, "the failed Mac request is not repeated for every later block")
    }

    func testAProbeThatFinishesAfterTheSettingsChangedDoesNotPoisonTheNewOnes() async {
        let gate = AsyncGate()
        let macUp = LockedFlag(false)
        let (s, t, engine) = fallbackSetup { r in
            if r.url.path == "/api/status" { await gate.wait(); if macUp.value { return serverUnauthorized() }; throw URLError(.cannotConnectToHost) }
            return okResponse(for: r)
        }
        async let first = s.translate(gen: 0, text: text)
        try? await Task.sleep(nanoseconds: 100_000_000)           // the old question is in flight (and will say "unreachable")
        await s.configurationChanged()                           // the person re-paired / changed the server
        await gate.release()                                      // the old question now gets its "unreachable"
        _ = await first
        macUp.value = true                                       // the (new) Mac is fine
        let before = t.requests.filter { $0.url.path == "/api/translate" }.count
        let out = await s.translate(gen: await s.generation, text: text + "。もう一文です、これも日本語です。")        // the page asks again with the new generation
        guard case .success = out else { return XCTFail("\(out)") }
        XCTAssertGreaterThan(t.requests.filter { $0.url.path == "/api/translate" }.count, before, "the new settings reach the Mac: the old \"unreachable\" was not kept")
        XCTAssertEqual(engine.calls.count, 0)                    // the first request became stale with the change; the second one reached the Mac
    }

    func testAWarmResolverDoesNotHideAMacThatWentToSleep() async {
        let clock = ManualClock()
        let cfg = ServerConfig(baseURL: URL(string: "https://mac.local:8000")!, token: "t", fallbackURL: URL(string: "https://192.168.0.19:8000")!, pinnedFingerprint: String(repeating: "ab", count: 32))
        let up = LockedFlag(true)
        let t = MockTransport { r, _ in
            if !up.value { throw URLError(.cannotConnectToHost) }
            return r.url.path == "/api/status" ? serverUnauthorized() : okResponse(for: r)
        }
        let box = EnginePrefsBox(); box.value.fallbackToDevice = true
        let provider = FakeProvider(); let engine = FakeSpanEngine(handler: numberedEnglish); provider.translators[.appleTranslation] = engine
        let s = TranslationService(transport: t, config: { cfg }, prefs: { (0.5, .phrase) }, clock: clock, resolver: EndpointResolver(transport: t, clock: clock),
                                   engines: provider, enginePrefs: { box.value })
        guard case .success = await s.translate(gen: 0, text: text) else { return XCTFail() }
        up.value = false
        clock.advance(65)                                         // past the 60 s memory, inside the resolver's 120 s
        let macTranslates = t.requests.filter { $0.url.path == "/api/translate" }.count
        guard case .success = await s.translate(gen: 0, text: text + "。もう一文です、これも日本語です。") else { return XCTFail() }
        XCTAssertEqual(t.requests.filter { $0.url.path == "/api/translate" }.count, macTranslates, "the Mac was asked quickly and found asleep: no long request was sent to it")
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testMeaningsAlsoShowACertificateProblemInsteadOfFallingBack() async {
        let box = EnginePrefsBox(); box.value.fallbackToDevice = true
        let provider = FakeProvider(); let def = FakeDefinitionEngine { _, _, _ in self.wordAnswer }; provider.definer = def
        let s = make(MockTransport { _, _ in throw PinMismatchError() }, prefs: box, provider: provider)
        let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .failure(.pinMismatch) = await s.define(req) else { return XCTFail() }
        XCTAssertEqual(def.count, 0)
    }

    func testWithoutFallbackAnUnreachableMacIsReported() async {
        let t = MockTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let box = EnginePrefsBox()
        let provider = FakeProvider(); let engine = FakeSpanEngine(handler: numberedEnglish); provider.translators[.appleTranslation] = engine
        let out = await make(t, prefs: box, provider: provider).translate(gen: 0, text: text)
        XCTAssertEqual(out, .failure(.unreachable))
        XCTAssertEqual(engine.calls.count, 0)
    }

    func testNoMacConfiguredWithFallbackUsesTheIPhone() async {
        let t = MockTransport { _, _ in HTTPResponse(status: 500) }
        let box = EnginePrefsBox(); box.value.fallbackToDevice = true
        let provider = FakeProvider(); provider.translators[.appleTranslation] = FakeSpanEngine(handler: numberedEnglish)
        let out = await make(t, prefs: box, provider: provider, config: false).translate(gen: 0, text: text)
        guard case .success = out else { return XCTFail("\(out)") }
        XCTAssertEqual(t.count, 0)
    }

    // ---- word / phrase cards
    let wordAnswer = #"{"matchInSource":"食べ","senses":[{"gloss":"持つ"},{"gloss":"食べる"},{"gloss":"経験する"}],"contextIndex":1,"lemma":"have","pos":"動詞"}"#

    func testOnDeviceMeaningCardIsValidatedLikeTheServer() async {
        let box = EnginePrefsBox(); box.value.meaning = .foundationModels
        let provider = FakeProvider(); provider.definer = FakeDefinitionEngine { _, _, _ in self.wordAnswer }
        let s = make(MockTransport { _, _ in XCTFail("no network"); return HTTPResponse(status: 500) }, prefs: box, provider: provider)
        let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .success(.word(let card)) = await s.define(req) else { return XCTFail() }
        XCTAssertEqual(card.contextMeaning, "食べる"); XCTAssertEqual(card.lemma, "have"); XCTAssertEqual(card.matchInSource, "食べ")
        XCTAssertEqual(card.contextIndex, 1)
    }

    func testAnUnusableOnDeviceAnswerIsRefused() async {
        let box = EnginePrefsBox(); box.value.meaning = .foundationModels
        for bad in ["not json", "{}", #"{"lemma":"have","senses":[],"contextIndex":0}"#, #"{"lemma":"日本","senses":[{"gloss":"a"}],"contextIndex":0}"#, #"{"lemma":"have","senses":[{"gloss":"持つ"}],"contextIndex":5}"#] {
            let provider = FakeProvider(); provider.definer = FakeDefinitionEngine { _, _, _ in bad }
            let s = make(MockTransport { _, _ in HTTPResponse(status: 500) }, prefs: box, provider: provider)
            let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
            guard case .failure(.deviceFailed) = await s.define(req) else { return XCTFail("accepted: \(bad)") }
        }
    }

    func testMatchInSourceIsOnlyKeptWhenItReallyIsInTheJapanese() async {
        let box = EnginePrefsBox(); box.value.meaning = .foundationModels
        let provider = FakeProvider(); provider.definer = FakeDefinitionEngine { _, _, _ in self.wordAnswer.replacingOccurrences(of: "食べ\"", with: "走った\"") }
        let s = make(MockTransport { _, _ in HTTPResponse(status: 500) }, prefs: box, provider: provider)
        let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .success(.word(let card)) = await s.define(req) else { return XCTFail() }
        XCTAssertNil(card.matchInSource)
    }

    func testTheSecondStepAndPhraseCardsWork_andAreCached() async {
        let box = EnginePrefsBox(); box.value.meaning = .foundationModels
        let provider = FakeProvider()
        let def = FakeDefinitionEngine { kind, detail, _ in
            switch (kind, detail) {
            case (.word, .more): return #"{"example":{"en":"I have a pen.","ja":"ペンを持っている。"},"phrases":["have to"],"note":"助動詞的にも使う"}"#
            case (.phrase, .basic): return #"{"meaning":"昼ご飯を食べる","nuance":"くだけた言い方"}"#
            default: return #"{"points":[{"expr":"have lunch","note":"食事をとる"}],"synonyms":["eat lunch"]}"#
            }
        }
        provider.definer = def
        let s = make(MockTransport { _, _ in HTTPResponse(status: 500) }, prefs: box, provider: provider)
        let w = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .more(.word(let ex, let phrases, _)) = await s.define(w, more: true, sense: "食べる") else { return XCTFail() }
        XCTAssertEqual(ex?.en, "I have a pen."); XCTAssertEqual(phrases, ["have to"])
        let p = LookupRequest.make(kind: .phrase, term: "I have lunch", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .success(.phrase(let card)) = await s.define(p) else { return XCTFail() }
        XCTAssertEqual(card.meaning, "昼ご飯を食べる")
        _ = await s.define(p)
        XCTAssertEqual(def.count, 2)                      // the repeat came from the cache
    }

    func testMeaningFallsBackToTheIPhoneWhenTheMacIsUnreachable() async {
        let box = EnginePrefsBox(); box.value.fallbackToDevice = true
        let provider = FakeProvider(); let def = FakeDefinitionEngine { _, _, _ in self.wordAnswer }; provider.definer = def
        let t = MockTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let s = make(t, prefs: box, provider: provider)
        let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .success = await s.define(req) else { return XCTFail() }
        XCTAssertEqual(def.count, 1)
        XCTAssertTrue(t.requests.allSatisfy { $0.url.path == "/api/status" })
    }

    func testFailureCodesAndFallbackRules() {
        XCTAssertTrue(TranslationFailure.unreachable.allowsDeviceFallback)
        XCTAssertTrue(TranslationFailure.timeout.allowsDeviceFallback)
        XCTAssertTrue(TranslationFailure.breakerOpen(5).allowsDeviceFallback)
        for f in [TranslationFailure.unauthorized, .pinMismatch, .certificateUntrusted, .invalidResponse, .stale, .cancelled, .rejected("x"), .server("x")] { XCTAssertFalse(f.allowsDeviceFallback, "\(f)") }
        XCTAssertEqual(TranslationFailure.deviceUnavailable("m").code, "device_unavailable")
        XCTAssertEqual(TranslationFailure.deviceFailed("m").message, "m")
    }
}

final class OnDeviceDefinitionTests: XCTestCase {
    func testServerResponseShapeDecodesWithTheAppsOwnDecoder() {
        let content = #"{"matchInSource":"","senses":[{"gloss":"持つ"}],"contextIndex":0,"lemma":"have","pos":"動詞"}"#
        let data = OnDeviceDefinition.serverResponse(kind: .word, detail: .basic, content: content, contextJapanese: "")
        XCTAssertNotNil(data)
        guard case .word(let c)? = data.flatMap({ DefinitionCard.decode(serverResponse: $0) }) else { return XCTFail() }
        XCTAssertEqual(c.contextMeaning, "持つ")
        XCTAssertNil(c.matchInSource)
    }
}

final class EngineSettingsTests: XCTestCase {
    func store() -> (SettingsStore, UserDefaults, String) {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: d, secrets: InMemorySecretStore()), d, suite)
    }

    func testDefaultsKeepTheMacAndNothingOnTheDevice() {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(s.enginePrefs, EnginePrefs())
        XCTAssertEqual(s.translationEngine, .mac); XCTAssertEqual(s.meaningEngine, .mac)
        XCTAssertFalse(s.fallbackToDevice)
    }

    func testChoicesAreStoredAndJunkFallsBack() {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        s.translationEngine = .foundationModels; s.meaningEngine = .foundationModels; s.fallbackToDevice = true; s.deviceTranslation = .foundationModels
        let p = s.enginePrefs
        XCTAssertEqual(p.translation, .foundationModels); XCTAssertEqual(p.meaning, .foundationModels); XCTAssertTrue(p.fallbackToDevice)
        XCTAssertEqual(p.deviceTranslation, .foundationModels)
        d.set("something-else", forKey: "mazemaze.engine.translation"); d.set("mac", forKey: "mazemaze.engine.deviceTranslation")
        XCTAssertEqual(s.translationEngine, .mac)
        XCTAssertEqual(s.deviceTranslation, .appleTranslation)          // the fallback is never the Mac itself
        s.deviceTranslation = .mac
        XCTAssertEqual(s.deviceTranslation, .appleTranslation)
    }
}

final class EnglishAnalyzerTests: XCTestCase {
    func testBaseFormAndPartOfSpeechComeFromTheSystemAnalysis() {
        XCTAssertEqual(EnglishAnalyzer.analyze(term: "took", context: "She took a stroll along the river")?.lemma, "take")
        XCTAssertEqual(EnglishAnalyzer.analyze(term: "took", context: "She took a stroll along the river")?.pos, "動詞")
        XCTAssertEqual(EnglishAnalyzer.analyze(term: "stroll", context: "She took a stroll along the river")?.pos, "名詞")
        XCTAssertEqual(EnglishAnalyzer.analyze(term: "have", context: "I have lunch at noon")?.lemma, "have")
        XCTAssertEqual(EnglishAnalyzer.analyze(term: "Have", context: "")?.lemma, "have")           // no context: the word alone
        XCTAssertNil(EnglishAnalyzer.analyze(term: "", context: "x"))
    }

    func testRefineReplacesTheModelsLemmaAndKeepsTheRestValidatable() throws {
        let raw = #"{"matchInSource":"食べ","senses":[{"gloss":"持つ"},{"gloss":"食べる"}],"contextIndex":1,"lemma":"e","pos":"x"}"#
        let refined = OnDeviceDefinition.refine(kind: .word, detail: .basic, term: "have", contextEnglish: "I have lunch", content: raw)
        let card = OnDeviceDefinition.card(kind: .word, detail: .basic, content: refined, contextJapanese: "昼食を食べます")
        XCTAssertEqual(card?["lemma"] as? String, "have")
        XCTAssertEqual(card?["contextMeaning"] as? String, "食べる")
        XCTAssertEqual(card?["pos"] as? String, "動詞")
        // a model that leaves lemma/pos out entirely still gets them
        let noLemma = OnDeviceDefinition.refine(kind: .word, detail: .basic, term: "took", contextEnglish: "She took a walk", content: #"{"matchInSource":"","senses":[{"gloss":"歩いた"}],"contextIndex":0}"#)
        XCTAssertEqual(OnDeviceDefinition.card(kind: .word, detail: .basic, content: noLemma, contextJapanese: "")?["lemma"] as? String, "take")
    }

    func testEnglishGlossesAreDroppedAndTheIndexFollows() {
        let raw = #"{"matchInSource":"","senses":[{"gloss":"voice"},{"gloss":"軽い"},{"gloss":"light"},{"gloss":"明るい"}],"contextIndex":3}"#
        let card = OnDeviceDefinition.card(kind: .word, detail: .basic, content: OnDeviceDefinition.refine(kind: .word, detail: .basic, term: "light", contextEnglish: "a light voice", content: raw), contextJapanese: "")
        XCTAssertEqual(card?["contextMeaning"] as? String, "明るい")
        XCTAssertEqual(card?["contextIndex"] as? Int, 1)
        XCTAssertEqual((card?["meanings"] as? [[String: String]])?.map { $0["meaning"] }, ["軽い", "明るい"])
        // the sense in context was the English one: nothing trustworthy is left
        let bad = #"{"matchInSource":"","senses":[{"gloss":"軽い"},{"gloss":"light"}],"contextIndex":1}"#
        XCTAssertNil(OnDeviceDefinition.card(kind: .word, detail: .basic, content: OnDeviceDefinition.refine(kind: .word, detail: .basic, term: "light", contextEnglish: "", content: bad), contextJapanese: ""))
    }

    func testMoreListsLoseSentencesAndRepeats() {
        let raw = #"{"example":{"en":"I have a pen.","ja":"ペンを持っている"},"phrases":["have to","I have a pen.","Do you have time?","have","take a walk"],"note":""}"#
        let card = OnDeviceDefinition.card(kind: .word, detail: .more, content: OnDeviceDefinition.refine(kind: .word, detail: .more, term: "have", contextEnglish: "", content: raw), contextJapanese: "")
        XCTAssertEqual(card?["phrases"] as? [String], ["have to", "take a walk"])
        let syn = #"{"points":[{"expr":"despite","note":"〜にもかかわらず"}],"synonyms":["Despite the rain","in spite of the rain"]}"#
        let p = OnDeviceDefinition.card(kind: .phrase, detail: .more, content: OnDeviceDefinition.refine(kind: .phrase, detail: .more, term: "despite the rain", contextEnglish: "", content: syn), contextJapanese: "")
        XCTAssertEqual(p?["synonyms"] as? [String], ["in spite of the rain"])
    }

    func testRefineNeverTurnsGarbageIntoACard() {
        XCTAssertEqual(OnDeviceDefinition.refine(kind: .word, detail: .basic, term: "a", contextEnglish: "", content: "not json"), "not json")
        XCTAssertNil(OnDeviceDefinition.card(kind: .word, detail: .basic, content: OnDeviceDefinition.refine(kind: .word, detail: .basic, term: "have", contextEnglish: "", content: "[]"), contextJapanese: ""))
    }
}

final class EngineRulesTests: XCTestCase {
    func prefs(_ t: TranslationEngineKind = .mac, _ m: MeaningEngineKind = .mac, fallback: Bool = false) -> EnginePrefs {
        var p = EnginePrefs(); p.translation = t; p.meaning = m; p.fallbackToDevice = fallback; return p
    }

    func testTheMacSetupPromptOnlyAppearsWhenNothingElseCouldTranslate() {
        XCTAssertTrue(EngineRules.needsMacSetup(prefs(), hasServerConfig: false))                            // the original first run
        XCTAssertFalse(EngineRules.needsMacSetup(prefs(), hasServerConfig: true))
        XCTAssertFalse(EngineRules.needsMacSetup(prefs(.appleTranslation), hasServerConfig: false))        // device-only, meaning still "Mac" by default
        XCTAssertFalse(EngineRules.needsMacSetup(prefs(.foundationModels, .foundationModels), hasServerConfig: false))
        XCTAssertFalse(EngineRules.needsMacSetup(prefs(fallback: true), hasServerConfig: false))           // the iPhone takes over: no prompt, no blocked screens
    }

    func testAHiddenFallbackFlagCannotBlockDeviceOnlyMode() {
        // fallback left on, then both engines moved to the iPhone with no Mac: still nothing to set up, and it can translate
        let p = prefs(.appleTranslation, .foundationModels, fallback: true)
        XCTAssertFalse(EngineRules.needsMacSetup(p, hasServerConfig: false))
        XCTAssertTrue(EngineRules.translationAvailable(p, hasServerConfig: false))
        XCTAssertTrue(EngineRules.meaningAvailable(p, hasServerConfig: false))
    }

    func testAvailability() {
        XCTAssertFalse(EngineRules.translationAvailable(prefs(), hasServerConfig: false))
        XCTAssertTrue(EngineRules.translationAvailable(prefs(), hasServerConfig: true))
        XCTAssertTrue(EngineRules.translationAvailable(prefs(.foundationModels), hasServerConfig: false))
        XCTAssertTrue(EngineRules.translationAvailable(prefs(fallback: true), hasServerConfig: false))
        XCTAssertFalse(EngineRules.meaningAvailable(prefs(.appleTranslation), hasServerConfig: false))      // meaning still on the Mac, no Mac
        XCTAssertTrue(EngineRules.meaningAvailable(prefs(.appleTranslation, .foundationModels), hasServerConfig: false))
    }
}

final class CardMakerTests: XCTestCase {
    let json = #"{"card":{"kind":"word","lemma":"have","pos":"動詞","contextMeaning":"持つ","contextIndex":0,"meanings":[{"meaning":"持つ"}]}}"#

    func testTheMakerIsRecordedAndNamed() throws {
        let card = try XCTUnwrap(DefinitionCard.decode(serverResponse: Data(json.utf8)))
        XCTAssertNil(card.maker)
        XCTAssertEqual(card.makerName, "Mac のローカルモデル")                          // a card from before this was recorded
        XCTAssertEqual(card.settingMaker(DefinitionCard.makerDevice).makerName, "iPhone の Apple Intelligence")
        XCTAssertEqual(card.settingMaker(DefinitionCard.makerMac).makerName, "Mac のローカルモデル")
        let phrase = DefinitionCard.phrase(PhraseCard(meaning: "x", nuance: nil, points: [], synonyms: [], examples: []))
        XCTAssertEqual(phrase.settingMaker(DefinitionCard.makerDevice).maker, "device")
    }

    func testOldSavedCardsStillDecodeAndTheMakerSurvivesSaving() throws {
        let old = #"{"kind":"word","word":{"lemma":"have","pos":"動詞","contextMeaning":"持つ","contextIndex":0,"meanings":[{"meaning":"持つ"}],"phrases":[]}}"#     // no "maker" key
        let card = try JSONDecoder().decode(DefinitionCard.self, from: Data(old.utf8))
        XCTAssertNil(card.maker)
        let saved = try JSONEncoder().encode(card.settingMaker("device"))
        XCTAssertEqual(try JSONDecoder().decode(DefinitionCard.self, from: saved).maker, "device")
    }

    func testTheServiceStampsTheEngineThatMadeTheCard() async {
        let box = EnginePrefsBox(); box.value.meaning = .foundationModels
        let provider = FakeProvider(); provider.definer = FakeDefinitionEngine { _, _, _ in #"{"matchInSource":"","senses":[{"gloss":"持つ"}],"contextIndex":0}"# }
        let s = TranslationService(transport: MockTransport { _, _ in HTTPResponse(status: 500) }, config: { nil }, prefs: { (0.5, .phrase) }, clock: ManualClock(), engines: provider, enginePrefs: { box.value })
        let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch", contextJapanese: "")!
        guard case .success(let c) = await s.define(req) else { return XCTFail() }
        XCTAssertEqual(c.maker, "device")
        let macJSON = #"{"card":{"kind":"word","lemma":"have","pos":"動詞","contextMeaning":"持つ","contextIndex":0,"meanings":[{"meaning":"持つ"}]}}"#
        let t = MockTransport { _, _ in HTTPResponse(status: 200, body: Data(macJSON.utf8)) }
        let mac = TranslationService(transport: t, config: { ServerConfig(baseURL: URL(string: "http://mac.local:8000")!, token: "t") }, prefs: { (0.5, .phrase) }, clock: ManualClock())
        guard case .success(let m) = await mac.define(req) else { return XCTFail() }
        XCTAssertEqual(m.maker, "mac")
    }
}
