import XCTest
@testable import MazemazeCore

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

final class OnDeviceMeaningServiceTests: XCTestCase {
    let wordAnswer = #"{"matchInSource":"食べ","senses":[{"gloss":"持つ"},{"gloss":"食べる"},{"gloss":"経験する"}],"contextIndex":1,"lemma":"have","pos":"動詞"}"#
    let req = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch at noon", contextJapanese: "私は昼ご飯を食べた")!

    func service(_ definer: FakeDefinitionEngine?) -> TranslationService { makeService(definer: definer) }

    func testTheCardIsValidatedLikeAnyModelAnswer() async {
        let s = service(FakeDefinitionEngine { _, _, _ in self.wordAnswer })
        guard case .success(.word(let card)) = await s.define(req) else { return XCTFail() }
        XCTAssertEqual(card.contextMeaning, "食べる"); XCTAssertEqual(card.lemma, "have"); XCTAssertEqual(card.matchInSource, "食べ")
        XCTAssertEqual(card.contextIndex, 1)
    }

    func testAnUnusableAnswerIsRefused() async {
        for bad in ["not json", "{}", #"{"lemma":"have","senses":[],"contextIndex":0}"#, #"{"lemma":"have","senses":[{"gloss":"持つ"}],"contextIndex":5}"#, #"{"senses":[{"gloss":"light"}],"contextIndex":0}"#] {
            let s = service(FakeDefinitionEngine { _, _, _ in bad })
            guard case .failure(.failed) = await s.define(req) else { return XCTFail("accepted: \(bad)") }
        }
    }

    func testTheModelsLemmaIsReplacedByTheSystemAnalysis() async {
        let s = service(FakeDefinitionEngine { _, _, _ in self.wordAnswer.replacingOccurrences(of: #""lemma":"have""#, with: #""lemma":"e""#) })
        guard case .success(.word(let card)) = await s.define(req) else { return XCTFail() }
        XCTAssertEqual(card.lemma, "have")
    }

    func testMatchInSourceIsOnlyKeptWhenItReallyIsInTheJapanese() async {
        let s = service(FakeDefinitionEngine { _, _, _ in self.wordAnswer.replacingOccurrences(of: "食べ\"", with: "走った\"") })
        guard case .success(.word(let card)) = await s.define(req) else { return XCTFail() }
        XCTAssertNil(card.matchInSource)
    }

    func testTheSecondStepAndPhraseCardsWork_andAreCached() async {
        let def = FakeDefinitionEngine { kind, detail, _ in
            switch (kind, detail) {
            case (.word, .more): return #"{"example":{"en":"I have a pen.","ja":"ペンを持っている。"},"phrases":["have to"],"note":"助動詞的にも使う"}"#
            case (.phrase, .basic): return #"{"meaning":"昼ご飯を食べる","nuance":"くだけた言い方"}"#
            default: return #"{"points":[{"expr":"have lunch","note":"食事をとる"}],"synonyms":["eat lunch"]}"#
            }
        }
        let s = service(def)
        guard case .more(.word(let ex, let phrases, _)) = await s.define(req, more: true, sense: "食べる") else { return XCTFail() }
        XCTAssertEqual(ex?.en, "I have a pen."); XCTAssertEqual(phrases, ["have to"])
        let p = LookupRequest.make(kind: .phrase, term: "I have lunch", contextEnglish: "I have lunch", contextJapanese: "私は昼ご飯を食べた")!
        guard case .success(.phrase(let card)) = await s.define(p) else { return XCTFail() }
        XCTAssertEqual(card.meaning, "昼ご飯を食べる")
        _ = await s.define(p)
        XCTAssertEqual(def.count, 2)                      // the repeat came from the cache
    }

    func testNoEngineMeansAnUnavailableMessage() async {
        guard case .failure(.unavailable(let m)) = await service(nil).define(req) else { return XCTFail() }
        XCTAssertTrue(m.contains("Apple Intelligence"))
    }

    func testAnEngineThatCannotRunIsReported() async {
        let s = service(FakeDefinitionEngine { _, _, _ in throw EngineError.unavailable("オンにしてください") })
        await assertEq(await s.define(req), .failure(.unavailable("オンにしてください")))
    }

    func testABackgroundLookupWaitsForQuietAndThenRuns() async {
        let def = FakeDefinitionEngine { _, _, _ in self.wordAnswer }
        let clock = ManualClock()
        let s = makeService(FakeSpanEngine(), clock: clock, definer: def)
        _ = await s.translate(gen: 0, text: "あいうえおのテキスト")            // reading just happened
        guard case .success = await s.define(req, background: true) else { return XCTFail() }
        XCTAssertFalse(clock.sleeps.isEmpty, "it waited for a quiet moment instead of competing with reading")
        XCTAssertEqual(def.count, 1)
    }
}

final class EngineSettingsTests: XCTestCase {
    func testTheDefaultIsAppleTranslationAndAnOldChoiceOfTheMacFallsBack() {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.translationEngine, .appleTranslation)
        s.translationEngine = .foundationModels
        XCTAssertEqual(s.translationEngine, .foundationModels)
        d.set("mac", forKey: "mazemaze.engine.translation")          // a setting left by the version that had a Mac
        XCTAssertEqual(s.translationEngine, .appleTranslation)
    }
}
