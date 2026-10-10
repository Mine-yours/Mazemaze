import XCTest
@testable import MazemazeCore

private let wordCardJSON: [String: Any] = [
    "kind": "word", "lemma": "have", "pos": "動詞", "contextMeaning": "持つ・所有する", "contextIndex": 0, "matchInSource": "持っています",
    "meanings": [["meaning": "持つ・所有する"], ["meaning": "食べる・飲む"], ["meaning": "経験する"]],
]
private let wordMoreJSON: [String: Any] = [
    "kind": "word_more", "example": ["en": "I have a pen.", "ja": "私はペンを持っています。"], "phrases": ["have to", "have been"], "note": "have to は「〜しなければならない」",
]
private let phraseMoreJSON: [String: Any] = [
    "kind": "phrase_more", "points": [["expr": "have", "note": "所有"]], "synonyms": ["I've got a pen"], "example": ["en": "I have a red pen.", "ja": "赤いペンを持っています。"],
]

final class DefinitionModelTests: XCTestCase {
    func testLookupRequestValidation() {
        XCTAssertNotNil(LookupRequest.make(kind: .word, term: " have ", contextEnglish: "I have a pen", contextJapanese: "ペンを持っています"))
        XCTAssertEqual(LookupRequest.make(kind: .word, term: " have ", contextEnglish: "a\nb", contextJapanese: "")?.term, "have")
        XCTAssertNil(LookupRequest.make(kind: .word, term: "have a", contextEnglish: "", contextJapanese: ""), "a word is one word")
        XCTAssertNil(LookupRequest.make(kind: .word, term: "123", contextEnglish: "", contextJapanese: ""))
        XCTAssertNil(LookupRequest.make(kind: .word, term: String(repeating: "a", count: 41), contextEnglish: "", contextJapanese: ""))
        XCTAssertNil(LookupRequest.make(kind: .phrase, term: "   ", contextEnglish: "", contextJapanese: ""))
        XCTAssertNil(LookupRequest.make(kind: .phrase, term: String(repeating: "a", count: 301), contextEnglish: "", contextJapanese: ""))
        let long = LookupRequest.make(kind: .phrase, term: "I have a pen", contextEnglish: "", contextJapanese: String(repeating: "あ", count: 900))
        XCTAssertEqual(long?.contextJapanese.unicodeScalars.count, LookupRequest.maxContextScalars, "context is cut, not refused")
        let hidden = LookupRequest.make(kind: .phrase, term: "ab\u{202E}c\u{0}d", contextEnglish: "", contextJapanese: "")
        XCTAssertEqual(hidden?.term, "abc d", "direction overrides are dropped, control characters become spaces")
    }

    func testEnglishWords() {
        XCTAssertEqual(EnglishWords.words(in: "I have a pen. I don't have it; well-known!"), ["I", "have", "a", "pen", "don't", "it", "well-known"])
        XCTAssertEqual(EnglishWords.words(in: "日本語だけ"), [])
        XCTAssertEqual(EnglishWords.words(in: "Take take TAKE"), ["Take"])
    }

    func testDecodeWordCard() {
        guard case .word(let c)? = DefinitionCard.decode(serverResponse: try! JSONSerialization.data(withJSONObject: ["card": wordCardJSON])) else { return XCTFail() }
        XCTAssertEqual(c.lemma, "have"); XCTAssertEqual(c.contextMeaning, "持つ・所有する"); XCTAssertEqual(c.contextIndex, 0)
        XCTAssertEqual(c.meanings.map(\.meaning), ["持つ・所有する", "食べる・飲む", "経験する"])
        XCTAssertEqual(c.matchInSource, "持っています"); XCTAssertFalse(c.hasMore)
        // The second step is merged in: the example goes to the sense in context.
        let more = DefinitionMore.decode(serverResponse: try! JSONSerialization.data(withJSONObject: ["card": wordMoreJSON]))
        guard case .word(let merged)? = DefinitionCard.word(c).merging(more!) as DefinitionCard? else { return XCTFail() }
        XCTAssertEqual(merged.meanings[0].exampleEn, "I have a pen."); XCTAssertNil(merged.meanings[1].exampleEn)
        XCTAssertEqual(merged.phrases, ["have to", "have been"]); XCTAssertTrue(merged.hasMore)
    }

    func testDecodeRefusesWhatIsNotClean() {
        func decode(_ card: [String: Any]) -> DefinitionCard? { DefinitionCard.decode(serverResponse: try! JSONSerialization.data(withJSONObject: ["card": card])) }
        var bad = wordCardJSON; bad["lemma"] = "日本語"
        XCTAssertNil(decode(bad), "the lemma must be a Latin word")
        bad = wordCardJSON; bad["contextMeaning"] = "持って\u{202E}いる"
        XCTAssertNil(decode(bad), "direction override characters are refused")
        bad = wordCardJSON; bad["contextMeaning"] = String(repeating: "あ", count: 41)
        XCTAssertNil(decode(bad))
        bad = wordCardJSON; bad["kind"] = "idiom"
        XCTAssertNil(decode(bad))
        var many = wordCardJSON; many["meanings"] = (0..<10).map { ["meaning": "m\($0)"] } + [["meaning": "x\u{0}y"], "junk"]; many["contextMeaning"] = "m3"; many["contextIndex"] = 3
        guard case .word(let c)? = decode(many) else { return XCTFail() }
        XCTAssertEqual(c.meanings.count, 5, "at most five senses"); XCTAssertEqual(c.contextIndex, 3)
        var onlyContext = wordCardJSON; onlyContext["meanings"] = "bad"
        guard case .word(let o)? = decode(onlyContext) else { return XCTFail() }
        XCTAssertEqual(o.meanings.map(\.meaning), ["持つ・所有する"])
        var wrongIndex = wordCardJSON; wrongIndex["contextIndex"] = 2          // points at another sense: the context sense wins
        guard case .word(let w)? = decode(wrongIndex) else { return XCTFail() }
        XCTAssertEqual(w.contextIndex, 0)
        XCTAssertNil(DefinitionMore.decode(serverResponse: try! JSONSerialization.data(withJSONObject: ["card": ["kind": "word_more", "phrases": [], "note": "a\u{202E}b"]])))
        XCTAssertNil(DefinitionCard.decode(serverResponse: Data("[]".utf8)))
        XCTAssertNil(DefinitionCard.decode(serverResponse: Data("not json".utf8)))
    }

    func testDecodePhraseCard() {
        let json: [String: Any] = ["kind": "phrase", "meaning": "私はペンを持っています", "nuance": "基本的な言い方"]
        guard case .phrase(let c)? = DefinitionCard.decode(serverResponse: try! JSONSerialization.data(withJSONObject: ["card": json])) else { return XCTFail() }
        XCTAssertEqual(DefinitionCard.phrase(c).headline, "私はペンを持っています"); XCTAssertFalse(c.hasMore)
        let more = DefinitionMore.decode(serverResponse: try! JSONSerialization.data(withJSONObject: ["card": phraseMoreJSON]))!
        guard case .phrase(let m) = DefinitionCard.phrase(c).merging(more) else { return XCTFail() }
        XCTAssertEqual(m.points, [PhrasePoint(expr: "have", note: "所有")]); XCTAssertEqual(m.synonyms, ["I've got a pen"]); XCTAssertEqual(m.examples.count, 1)
        XCTAssertEqual(DefinitionCard.phrase(c).merging(DefinitionMore.word(example: nil, phrases: ["x"], note: nil)), DefinitionCard.phrase(c), "a mismatched step changes nothing")
    }

    func testCardsSurviveStorageAndOldFilesStillLoad() throws {
        var d = DictionaryData()
        guard case .word(let w)? = DefinitionCard.decode(serverResponse: try JSONSerialization.data(withJSONObject: ["card": wordCardJSON])) else { return XCTFail() }
        guard case .added(let e) = d.addWord(w, source: "x.com", sourceURL: nil, now: Date(timeIntervalSince1970: 1_800_000_000)) else { return XCTFail() }
        XCTAssertEqual(e.kind, .word); XCTAssertEqual(e.english, "have"); XCTAssertEqual(e.japanese, "持つ・所有する")
        guard case .duplicate = d.addWord(w, source: "other", sourceURL: nil) else { return XCTFail("the same sense is a duplicate") }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(DictionaryData.self, from: try enc.encode(d)), d)
        XCTAssertEqual(d.search("食べる").count, 1, "the senses on the card are searchable")
        XCTAssertTrue(d.csv().contains(",word,持つ・所有する / 食べる・飲む / 経験する,"))
        // A version-1 file (no kind, no card) loads as ordinary expressions.
        let v1 = #"{"version":1,"entries":[{"id":"00000000-0000-0000-0000-000000000001","english":"good weather","japanese":"良い天気","source":"x.com","note":"","savedAt":"2027-01-01T00:00:00Z"}]}"#
        let old = try dec.decode(DictionaryData.self, from: Data(v1.utf8))
        XCTAssertEqual(old.entries.first?.kind, .expression); XCTAssertNil(old.entries.first?.card)
        // An unreadable card never loses the entry.
        let bad = #"{"version":2,"entries":[{"id":"00000000-0000-0000-0000-000000000002","kind":"word","english":"a","japanese":"あ","source":"","note":"","savedAt":"2027-01-01T00:00:00Z","card":{"kind":"zzz"}}]}"#
        let kept = try dec.decode(DictionaryData.self, from: Data(bad.utf8))
        XCTAssertEqual(kept.entries.count, 1); XCTAssertNil(kept.entries.first?.card)
    }

    func testBridgeLookupMessage() {
        let ok: [String: Any] = ["type": "lookup", "kind": "word", "term": "have", "en": "I have a pen", "ja": "ペンを持っています"]
        guard case .success(.lookup(let r)) = BridgeMessage.parse(ok) else { return XCTFail() }
        XCTAssertEqual(r.term, "have"); XCTAssertEqual(r.kind, .word)
        func bad(_ edit: (inout [String: Any]) -> Void) -> Bool { var m = ok; edit(&m); if case .failure = BridgeMessage.parse(m) { return true }; return false }
        XCTAssertTrue(bad { $0["url"] = "https://evil.example/" })
        XCTAssertTrue(bad { $0["kind"] = "idiom" })
        XCTAssertTrue(bad { $0["term"] = "have a" })
        XCTAssertTrue(bad { $0["term"] = 5 })
        XCTAssertTrue(bad { $0["ja"] = String(repeating: "あ", count: 2500) })
        XCTAssertTrue(bad { $0.removeValue(forKey: "en") })
    }
}

final class LookupPriorityTests: XCTestCase {
    let request = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have a pen", contextJapanese: "ペンを持っています")!
    let answer = #"{"matchInSource":"持って","senses":[{"gloss":"持つ"},{"gloss":"食べる"}],"contextIndex":0}"#

    func testABackgroundLookupWaitsForAQuietMomentAndLetsTranslationGoFirst() async {
        let clock = ManualClock(); let order = OrderBox()
        let engine = FakeSpanEngine { t, spans in order.add(t); return try await numberedEnglish(t, spans) }
        let def = FakeDefinitionEngine { _, _, _ in order.add("define"); return self.answer }
        var options = TranslationService.Options(); options.backgroundIdle = 10
        let s = makeService(engine, clock: clock, definer: def, options: options)
        _ = await s.translate(gen: 0, text: "読んでいる最中の文章です")          // reading just happened
        let started = clock.now()
        guard case .success = await s.define(request, background: true) else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(clock.now() - started, 10 - 2, "it waited for the idle time (in steps of 2 s) before making the card")
        XCTAssertEqual(order.all, ["読んでいる最中の文章です", "define"])
    }

    func testABackgroundLookupStartedFirstStillWaitsForEveryTranslation() async {
        let gate = AsyncGate(); let order = OrderBox()
        let engine = FakeSpanEngine { t, spans in order.add(t); return try await numberedEnglish(t, spans) }
        engine.gates["最初のテキストです"] = gate
        let def = FakeDefinitionEngine { _, _, _ in order.add("define"); return self.answer }
        var options = TranslationService.Options(); options.backgroundIdle = 0
        let s = makeService(engine, definer: def, options: options)
        let first = Task { await s.translate(gen: 0, text: "最初のテキストです") }
        while engine.count < 1 { try? await Task.sleep(nanoseconds: 5_000_000) }
        let background = Task { await s.define(request, background: true) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let second = Task { await s.translate(gen: 0, text: "二番目のテキストです") }
        try? await Task.sleep(nanoseconds: 60_000_000)
        await gate.release()
        _ = await first.value; _ = await second.value; _ = await background.value
        XCTAssertEqual(order.all, ["最初のテキストです", "二番目のテキストです", "define"], "the background lookup was asked first, but waits until no translation is running or waiting")
    }

    func testALookupGoesBeforeWaitingTranslations() async {
        let gate = AsyncGate(); let order = OrderBox()
        let engine = FakeSpanEngine { t, spans in order.add(t); return try await numberedEnglish(t, spans) }
        engine.gates["最初のテキストです"] = gate
        let def = FakeDefinitionEngine { _, _, _ in order.add("define"); return self.answer }
        let s = makeService(engine, definer: def)
        let first = Task { await s.translate(gen: 0, text: "最初のテキストです") }
        while engine.count < 1 { try? await Task.sleep(nanoseconds: 5_000_000) }
        let second = Task { await s.translate(gen: 0, text: "二番目のテキストです") }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let lookup = Task { await s.define(request) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        await gate.release()
        _ = await first.value; _ = await second.value; _ = await lookup.value
        XCTAssertEqual(order.all, ["最初のテキストです", "define", "二番目のテキストです"], "the lookup jumps the queue; one request at a time")
        XCTAssertEqual(engine.maxActive, 1)
    }
}
