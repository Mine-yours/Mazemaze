import XCTest
@testable import MazemazeCore

final class TranslationServiceTests: XCTestCase {
    func testReplacesOnlyTheChosenSpans_andNeverTouchesTheNetwork() async {
        let engine = FakeSpanEngine()
        let s = makeService(engine)
        let text = "今日は天気がいいので、友達と一緒に新しいカフェで朝ごはんを食べた。"
        let out = await s.translate(gen: 0, text: text)
        guard case .success(let segs) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(segs.map(\.source).joined(), text)
        XCTAssertTrue(segs.contains { $0.kind == .en })
    }

    func testSerializesConcurrentRequests() async {
        let engine = FakeSpanEngine { t, spans in try await Task.sleep(nanoseconds: 15_000_000); return try await numberedEnglish(t, spans) }
        let s = makeService(engine)
        let words = ["あいうえお", "かきくけこ", "さしすせそ", "たちつてと", "なにぬねの", "はひふへほ"]
        await withTaskGroup(of: TranslationOutcome.self) { g in
            for w in words { g.addTask { await s.translate(gen: 0, text: "\(w)のテキストです") } }
            for await o in g { if case .failure = o { XCTFail("unexpected failure") } }
        }
        XCTAssertEqual(engine.count, 6)
        XCTAssertEqual(engine.maxActive, 1)
    }

    func testCacheAndKeyDimensions() async {
        let engine = FakeSpanEngine(); let prefs = PrefsBox(); let kind = EngineKindBox()
        let s = makeService(engine, prefs: prefs, kind: kind)
        _ = await s.translate(gen: 0, text: "同じテキストです")
        _ = await s.translate(gen: 0, text: "同じテキストです")
        XCTAssertEqual(engine.count, 1)
        prefs.value = (0.5, .phrase); _ = await s.translate(gen: 0, text: "同じテキストです")
        prefs.value = (0.5, .sentence); _ = await s.translate(gen: 0, text: "同じテキストです")
        XCTAssertEqual(engine.count, 3)
        // delimiter-like characters in the text cannot collide with another key
        _ = await s.translate(gen: 0, text: "あいう|えお かき")
        _ = await s.translate(gen: 0, text: "あいう えお かき")
        XCTAssertEqual(engine.count, 5)
        await s.configurationChanged()
        let g = await s.generation
        _ = await s.translate(gen: g, text: "同じテキストです")
        XCTAssertEqual(engine.count, 6)
    }

    func testEnginesHaveSeparateCaches() async {
        let apple = FakeSpanEngine("apple") { _, spans in Dictionary(uniqueKeysWithValues: spans.map { ($0.id, "From apple") }) }
        let fm = FakeSpanEngine("fm") { _, spans in Dictionary(uniqueKeysWithValues: spans.map { ($0.id, "From model") }) }
        let provider = FakeProvider(); provider.translators = [.appleTranslation: apple, .foundationModels: fm]
        let kind = EngineKindBox()
        let s = TranslationService(engines: provider, engine: { kind.value }, prefs: { (0.5, .phrase) }, clock: ManualClock())
        let first = await s.translate(gen: 0, text: "同じテキストです")
        kind.value = .foundationModels
        let second = await s.translate(gen: 0, text: "同じテキストです")
        XCTAssertNotEqual(first, second)
        guard case .success(let segs) = second else { return XCTFail() }
        XCTAssertTrue(segs.contains { $0.display.lowercased().contains("from model") })
    }

    func testCacheEvictsOldest() async {
        var o = TranslationService.Options(); o.cacheCapacity = 2
        let engine = FakeSpanEngine(); let s = makeService(engine, options: o)
        for x in ["一つ目のテキスト", "二つ目のテキスト", "三つ目のテキスト"] { _ = await s.translate(gen: 0, text: x) }
        let cached = await s.cachedCount
        XCTAssertEqual(cached, 2)
        _ = await s.translate(gen: 0, text: "一つ目のテキスト")        // evicted -> asked again
        XCTAssertEqual(engine.count, 4)
    }

    func testFailuresAreNotCached() async {
        let first = FirstCall()
        let engine = FakeSpanEngine { t, spans in if first.isFirst() { throw EngineError.failed("x") }; return try await numberedEnglish(t, spans) }
        let s = makeService(engine)
        let a = await s.translate(gen: 0, text: "失敗のあとのテキスト")
        guard case .failure(.failed(let m)) = a else { return XCTFail("\(a)") }
        XCTAssertTrue(m.contains("原文はそのまま"))
        let b = await s.translate(gen: 0, text: "失敗のあとのテキスト")
        guard case .success = b else { return XCTFail() }
    }

    func testAMissingEngineIsAnUnavailableMessage() async {
        let s = TranslationService(engines: FakeProvider(), engine: { .foundationModels }, prefs: { (0.5, .phrase) }, clock: ManualClock())
        let out = await s.translate(gen: 0, text: "あいうえおのテキスト")
        guard case .failure(.unavailable(let m)) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(m.contains("Apple Intelligence"))
        XCTAssertEqual(TranslationFailure.unavailable("m").code, "not_configured")       // the page script stops asking until the settings change
    }

    func testAnUnavailableEngineIsReportedWithItsReason() async {
        let engine = FakeSpanEngine { _, _ in throw EngineError.unavailable("翻訳データが未ダウンロードです") }
        let out = await makeService(engine).translate(gen: 0, text: "あいうえおのテキスト")
        XCTAssertEqual(out, .failure(.unavailable("翻訳データが未ダウンロードです")))
    }

    func testStaleGenerationInFlightFinishesAndIsCachedButReportedStale() async {
        let gate = AsyncGate(); let engine = FakeSpanEngine()
        engine.gates["待たされるテキスト"] = gate
        let s = makeService(engine)
        let task = Task { await s.translate(gen: 0, text: "待たされるテキスト") }
        while engine.count == 0 { await Task.yield() }
        let newGen = await s.bumpGeneration()
        await gate.release()
        await assertEq(await task.value, .failure(.stale))                 // the page has moved on
        let again = await s.translate(gen: newGen, text: "待たされるテキスト")
        guard case .success = again else { return XCTFail("result should have been cached") }
        XCTAssertEqual(engine.count, 1)                                    // and was not asked again
    }

    func testWaitingRequestsBecomeStaleAfterBump() async {
        let gate = AsyncGate(); let engine = FakeSpanEngine()
        engine.gates["先頭のテキストです"] = gate
        let s = makeService(engine)
        let a = Task { await s.translate(gen: 0, text: "先頭のテキストです") }
        while engine.count == 0 { await Task.yield() }
        let b = Task { await s.translate(gen: 0, text: "待っているテキスト") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await s.bumpGeneration()
        await assertEq(await b.value, .failure(.stale))
        await gate.release()
        _ = await a.value
        XCTAssertEqual(engine.count, 1)                                    // B never reached the engine
        let g = await s.generation
        guard case .success = await s.translate(gen: g, text: "新しい世代のテキスト") else { return XCTFail("slot must have been released") }
    }

    func testCancelledWaiterDoesNotLeakTheSlot() async {
        let gate = AsyncGate(); let engine = FakeSpanEngine()
        engine.gates["先頭のテキストです"] = gate
        let s = makeService(engine)
        let a = Task { await s.translate(gen: 0, text: "先頭のテキストです") }
        while engine.count == 0 { await Task.yield() }
        let b = Task { await s.translate(gen: 0, text: "キャンセルされるテキスト") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        b.cancel()
        await assertEq(await b.value, .failure(.cancelled))
        await gate.release()
        _ = await a.value
        guard case .success = await s.translate(gen: 0, text: "そのあとのテキスト") else { return XCTFail() }
        XCTAssertEqual(engine.count, 2)
    }

    func testAPartlyFailedResultIsNotCached() async {
        let many = (1...12).map { "今日は天気がいい\($0 % 2 == 0 ? "です" : "ね")、とても楽しかった。" }.joined()      // several batches
        let first = FirstCall()
        let engine = FakeSpanEngine { t, spans in if first.isFirst() { throw EngineError.failed("once") }; return try await numberedEnglish(t, spans) }
        let s = makeService(engine)
        guard case .success = await s.translate(gen: 0, text: many) else { return XCTFail() }
        let afterFirst = engine.count
        _ = await s.translate(gen: 0, text: many)                  // asked again: the partly Japanese result was not kept
        XCTAssertGreaterThan(engine.count, afterFirst)
    }

    func testAnEngineThatIsCancelledReportsCancelled_andOneOverrunByANewPageReportsStale() async {
        let engine = FakeSpanEngine { _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return [:] }
        let s = makeService(engine)
        let task = Task { await s.translate(gen: 0, text: "あいうえおのテキスト") }
        while engine.count == 0 { await Task.yield() }
        task.cancel()
        await assertEq(await task.value, .failure(.cancelled))

        let engine2 = FakeSpanEngine { _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return [:] }
        let s2 = makeService(engine2)
        let task2 = Task { await s2.translate(gen: 0, text: "かきくけこのテキスト") }
        while engine2.count == 0 { await Task.yield() }
        await s2.bumpGeneration()
        task2.cancel()
        await assertEq(await task2.value, .failure(.stale))
    }

    func testBadTextIsRefusedAndNeverReachesTheEngine() async {
        let engine = FakeSpanEngine(); let s = makeService(engine)
        let out = await s.translate(gen: 0, text: "")
        guard case .failure(.rejected) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(engine.count, 0)
    }

    func testPerGenerationLimit() async {
        var o = TranslationService.Options(); o.maxRequestsPerGeneration = 3
        let s = makeService(options: o)
        for w in ["あいうえお", "かきくけこ", "さしすせそ"] { _ = await s.translate(gen: 0, text: "\(w)のテキスト") }
        await assertEq(await s.translate(gen: 0, text: "たちつてとのテキスト"), .failure(.limitReached))
        let g = await s.bumpGeneration()
        guard case .success = await s.translate(gen: g, text: "たちつてとのテキスト") else { return XCTFail() }
    }

    func testBridgePayloadHasOnlyWhatThePageNeeds() {
        let ok = TranslationOutcome.success([TranslatedSegment(kind: .en, source: "日本語", display: "Japanese")]).bridgePayload()
        XCTAssertEqual(Set(ok.keys), ["ok", "segments"])
        let bad = TranslationOutcome.failure(.failed("理由")).bridgePayload()
        XCTAssertEqual(bad["ok"] as? Bool, false); XCTAssertEqual(bad["error"] as? String, "server"); XCTAssertEqual(bad["message"] as? String, "理由")
    }
}

final class ScopeTests: XCTestCase {
    func testTabsHaveIndependentGenerations() async {
        let s = makeService()
        let a = await s.bumpGeneration(scope: 1)
        _ = await s.bumpGeneration(scope: 2)
        _ = await s.bumpGeneration(scope: 2)
        XCTAssertEqual(a, 1); await assertEq(await s.generation(of: 1), 1); await assertEq(await s.generation(of: 2), 2)
        guard case .success = await s.translate(scope: 1, gen: 1, text: "タブ一のテキストです") else { return XCTFail() }
        await assertEq(await s.translate(scope: 2, gen: 1, text: "タブ二の古い世代のテキスト"), .failure(.stale))
        _ = await s.bumpGeneration(scope: 1)       // tab 1 navigates
        guard case .success = await s.translate(scope: 2, gen: 2, text: "タブ二は影響を受けないテキスト") else { return XCTFail("tab 2 must not go stale when tab 1 navigates") }
    }

    func testTheTabOnScreenGoesFirst() async {
        let gate = AsyncGate(); let engine = FakeSpanEngine()
        engine.gates["先頭の要求です"] = gate
        let s = makeService(engine)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        await s.setActiveScope(2)
        let head = Task { await s.translate(scope: 1, gen: 1, text: "先頭の要求です") }
        while engine.count == 0 { await Task.yield() }
        let bg = Task { await s.translate(scope: 1, gen: 1, text: "背景タブの要求です") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let fg = Task { await s.translate(scope: 2, gen: 1, text: "前面タブの要求です") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await gate.release()
        _ = await head.value; _ = await bg.value; _ = await fg.value
        XCTAssertEqual(engine.texts, ["先頭の要求です", "前面タブの要求です", "背景タブの要求です"])
    }

    func testEveryWaitingRequestIsEventuallyServed() async {
        let s = makeService()
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        await s.setActiveScope(2)
        async let bg = s.translate(scope: 1, gen: 1, text: "背景だけの要求ですよ")
        async let f1 = s.translate(scope: 2, gen: 1, text: "前面の要求その一です")
        async let f2 = s.translate(scope: 2, gen: 1, text: "前面の要求その二です")
        for r in await [bg, f1, f2] { guard case .success = r else { return XCTFail("\(r)") } }
    }

    func testClosingATabDropsItsWaitersAndState() async {
        let gate = AsyncGate(); let engine = FakeSpanEngine()
        engine.gates["占有する要求です"] = gate
        let s = makeService(engine)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        let hold = Task { await s.translate(scope: 1, gen: 1, text: "占有する要求です") }
        while engine.count == 0 { await Task.yield() }
        let waiting = Task { await s.translate(scope: 2, gen: 1, text: "閉じられるタブの要求です") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await s.removeScope(2)
        await assertEq(await waiting.value, .failure(.stale))
        await gate.release()
        _ = await hold.value
        XCTAssertEqual(engine.count, 1)
        await assertGreater(await s.generation(of: 2), 0)          // the bumped generation stays: a late reply can never match again
    }

    func testConfigurationChangeStalesEveryTab() async {
        let s = makeService()
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        await s.configurationChanged()
        await assertEq(await s.translate(scope: 1, gen: 1, text: "設定変更のあとのテキストＡ"), .failure(.stale))
        await assertEq(await s.translate(scope: 2, gen: 1, text: "設定変更のあとのテキストＢ"), .failure(.stale))
    }

    func testRequestLimitIsPerTab() async {
        var o = TranslationService.Options(); o.maxRequestsPerGeneration = 2
        let s = makeService(options: o)
        _ = await s.bumpGeneration(scope: 1); _ = await s.bumpGeneration(scope: 2)
        for w in ["あいうえお", "かきくけこ"] { _ = await s.translate(scope: 1, gen: 1, text: "タブ一の\(w)です") }
        await assertEq(await s.translate(scope: 1, gen: 1, text: "タブ一の上限超えの要求"), .failure(.limitReached))
        guard case .success = await s.translate(scope: 2, gen: 1, text: "タブ二はまだ使える要求") else { return XCTFail() }
    }
}
