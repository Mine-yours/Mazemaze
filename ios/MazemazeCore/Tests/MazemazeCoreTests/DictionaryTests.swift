import XCTest
@testable import MazemazeCore

final class DictionaryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAddKeepsNewestFirstAndRefusesDuplicates() {
        var d = DictionaryData()
        guard case .added(let a) = d.add(english: "good weather", japanese: "良い天気", source: "x.com", sourceURL: URL(string: "https://x.com/jack/status/20"), now: t0) else { return XCTFail() }
        guard case .added(let b) = d.add(english: "stroll", japanese: "散歩", source: "x.com", sourceURL: nil, now: t0.addingTimeInterval(5)) else { return XCTFail() }
        XCTAssertEqual(d.entries.map(\.id), [b.id, a.id])
        guard case .duplicate(let dup) = d.add(english: "  Good   Weather ", japanese: "良い天気", source: "other", sourceURL: nil) else { return XCTFail("same expression, other case/spacing") }
        XCTAssertEqual(dup.id, a.id)
        XCTAssertEqual(d.entries.count, 2)
        guard case .added = d.add(english: "good weather", japanese: "いい天気", source: "x.com", sourceURL: nil) else { return XCTFail("a different original is a different entry") }
    }

    func testValidationCleansAndLimits() {
        var d = DictionaryData()
        XCTAssertEqual(d.add(english: " ", japanese: "x", source: "", sourceURL: nil), .rejected(.empty))
        XCTAssertEqual(d.add(english: "ok", japanese: "\n\t", source: "", sourceURL: nil), .rejected(.empty))
        let long = String(repeating: "あ", count: DictionaryData.maxTermScalars + 1)
        XCTAssertEqual(d.add(english: "ok", japanese: long, source: "", sourceURL: nil), .rejected(.tooLong))
        guard case .added(let e) = d.add(english: "a\u{0}b\nc\u{2028}d", japanese: "あ\u{3000}\u{3000}い", source: "s", sourceURL: nil) else { return XCTFail() }
        XCTAssertEqual(e.english, "a b c d"); XCTAssertEqual(e.japanese, "あ い")
    }

    func testOnlyPublicPagesKeepTheirURL() {
        var d = DictionaryData()
        guard case .added(let a) = d.add(english: "one", japanese: "一つ", source: "x.com", sourceURL: URL(string: "https://x.com/jack/status/20?s=1#a")) else { return XCTFail() }
        XCTAssertEqual(a.sourceURL?.absoluteString, "https://x.com/jack/status/20")          // query and fragment are dropped
        guard case .added(let b) = d.add(english: "two", japanese: "二つ", source: "mail", sourceURL: URL(string: "https://mail.example.com/inbox/1")) else { return XCTFail() }
        XCTAssertNil(b.sourceURL)
        guard case .added(let c) = d.add(english: "three", japanese: "三つ", source: DictionaryData.pasteSource, sourceURL: PasteSurface.url) else { return XCTFail() }
        XCTAssertNil(c.sourceURL)
    }

    func testCapacityIsBounded() {
        let items = (0..<DictionaryData.maxEntries).map { #"{"id":"\#(UUID().uuidString)","english":"e\#($0)","japanese":"日本語\#($0)","source":"","note":"","savedAt":"2027-01-01T00:00:00Z"}"# }
        var d = try! { let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try dec.decode(DictionaryData.self, from: Data(#"{"version":1,"entries":[\#(items.joined(separator: ","))]}"#.utf8)) }()
        XCTAssertEqual(d.entries.count, DictionaryData.maxEntries)
        XCTAssertEqual(d.add(english: "more", japanese: "もっと", source: "", sourceURL: nil), .rejected(.full))
        guard case .duplicate = d.add(english: "e1", japanese: "日本語1", source: "", sourceURL: nil) else { return XCTFail("duplicates are reported even when full") }
    }

    func testSearchNoteAndRemove() {
        var d = DictionaryData()
        guard case .added(let a) = d.add(english: "Prime Minister", japanese: "首相", source: "news.yahoo.co.jp", sourceURL: nil) else { return XCTFail() }
        d.add(english: "weather", japanese: "天気", source: "x.com", sourceURL: nil)
        XCTAssertEqual(d.search("prime").count, 1)
        XCTAssertEqual(d.search("首相 yahoo").count, 1)
        XCTAssertEqual(d.search("  ").count, 2)
        XCTAssertEqual(d.search("zzz").count, 0)
        d.setNote(id: a.id, note: "  国会で使う語\u{0} ")
        XCTAssertEqual(d.entries.first { $0.id == a.id }?.note, "国会で使う語")
        XCTAssertEqual(d.search("国会").count, 1)
        d.remove(id: a.id)
        XCTAssertEqual(d.entries.count, 1)
        XCTAssertFalse(d.contains(english: "prime minister", japanese: "首相"))
    }

    func testCSVEscapesAndNeutralisesFormulas() {
        var d = DictionaryData()
        d.add(english: "=SUM(1,2)", japanese: "式", source: "x.com", sourceURL: nil, now: t0)
        d.add(english: "say \"hi\", ok", japanese: "挨拶", source: "x.com", sourceURL: nil, now: t0)
        let rows = d.csv().components(separatedBy: "\r\n")
        XCTAssertEqual(rows[0], "english,japanese,source,url,note,saved_at")
        XCTAssertTrue(rows[1].hasPrefix("\"say \"\"hi\"\", ok\",挨拶,x.com,"))
        XCTAssertTrue(rows[2].hasPrefix("'=SUM(1,2)") || rows[2].hasPrefix("\"'=SUM(1,2)\""), rows[2])
        XCTAssertEqual(d.plainText(), "say \"hi\", ok — 挨拶\n=SUM(1,2) — 式")
    }

    func testStorageRoundTripAndNeverOverwritesUnreadableFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("d.json")
        let store = DictionaryStorage(fileURL: url)
        XCTAssertTrue(store.load().entries.isEmpty)
        var d = DictionaryData()
        d.add(english: "a", japanese: "あ", source: "x.com", sourceURL: nil, now: t0)
        XCTAssertTrue(store.save(d))
        XCTAssertEqual(DictionaryStorage(fileURL: url).load(), d)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let again = DictionaryStorage(fileURL: url)
        XCTAssertTrue(again.load().entries.isEmpty)
        XCTAssertNotNil(again.lastLoadProblem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the unreadable file is moved aside, not overwritten")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }.count, 1)
        // A file written by a newer version is also left alone.
        try #"{"version":99,"entries":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNotNil({ let s = DictionaryStorage(fileURL: url); _ = s.load(); return s.lastLoadProblem }())
    }

    func testAnUnreadableExistingFileIsNeverOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("d.json")
        var d = DictionaryData(); d.add(english: "a", japanese: "あ", source: "x.com", sourceURL: nil, now: t0)
        let store = DictionaryStorage(fileURL: url)
        XCTAssertTrue(store.save(d))
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)      // like a locked phone
        let locked = DictionaryStorage(fileURL: url)
        XCTAssertTrue(locked.load().entries.isEmpty)
        XCTAssertFalse(locked.isWritable)
        XCTAssertNotNil(locked.lastLoadProblem)
        var other = DictionaryData(); other.add(english: "b", japanese: "い", source: "", sourceURL: nil)
        XCTAssertFalse(locked.save(other), "saving must be refused while the file cannot be read")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original, "the saved words are untouched")
        XCTAssertEqual(locked.load().entries.count, 1)           // readable again: loads and writes again
        XCTAssertTrue(locked.isWritable)
    }

    func testInvisibleFormatCharactersAreDroppedAndCSVQuotesOnScalars() {
        var d = DictionaryData()
        guard case .added(let e) = d.add(english: "a\u{202E}b\u{200B}c", japanese: "あ\u{200D}い", source: "", sourceURL: nil) else { return XCTFail() }
        XCTAssertEqual(e.english, "abc")
        XCTAssertEqual(e.japanese, "あ\u{200D}い")
        d.add(english: "x,\u{301}y", japanese: "結合", source: "", sourceURL: nil)         // "," followed by a combining mark is one Character
        XCTAssertTrue(d.csv().contains("\"x,\u{301}y\""))
    }
}

