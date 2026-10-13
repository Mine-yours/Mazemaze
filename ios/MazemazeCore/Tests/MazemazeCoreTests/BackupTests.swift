import XCTest
@testable import MazemazeCore

final class BackupTests: XCTestCase {
    func entry(_ en: String, _ ja: String, at t: TimeInterval, kind: EntryKind = .expression, card: DefinitionCard? = nil, note: String = "") -> DictionaryEntry {
        DictionaryEntry(kind: kind, english: en, japanese: ja, source: "news.yahoo.co.jp", sourceURL: URL(string: "https://news.yahoo.co.jp/articles/a"), note: note,
                        savedAt: Date(timeIntervalSince1970: t), card: card)
    }

    func dictionary(_ entries: [DictionaryEntry]) -> DictionaryData {
        var d = DictionaryData()
        _ = d.merge(entries)
        return d
    }

    func card(_ meaning: String = "持つ") -> DefinitionCard {
        .word(WordCard(lemma: "have", pos: "動詞", contextMeaning: meaning, contextIndex: 0, meanings: [WordMeaning(meaning: meaning)], matchInSource: nil, phrases: [], note: nil))
    }

    // ---- file format
    func testRoundTripKeepsEverythingWorthKeeping() throws {
        var d = dictionary([entry("good weather", "良い天気", at: 100, note: "メモ"), entry("have", "持つ", at: 200, kind: .word, card: card())])
        var b = BookmarkData(); XCTAssertTrue(b.addFavorite(url: URL(string: "https://news.yahoo.co.jp/")!, title: "Yahoo"))
        let file = Backup.make(dictionary: d, favorites: b.favorites, allowedHosts: ["news.yahoo.co.jp", "example.jp"], now: Date(timeIntervalSince1970: 1_000_000))
        let data = try Backup.encode(file)
        let back = try Backup.decode(data)
        XCTAssertEqual(back.dictionary.entries.count, 2)
        XCTAssertEqual(back.dictionary.entries.first { $0.english == "have" }?.card, card())
        XCTAssertEqual(back.dictionary.entries.first { $0.english == "good weather" }?.note, "メモ")
        XCTAssertEqual(back.favorites.map(\.title), ["Yahoo"]); XCTAssertEqual(back.allowedHosts, ["news.yahoo.co.jp", "example.jp"])
        XCTAssertEqual(back.createdAt, Date(timeIntervalSince1970: 1_000_000))
        d.remove(id: d.entries[0].id)
        XCTAssertEqual(back.dictionary.entries.count, 2, "the file is independent of the live dictionary")
    }

    func testWhatIsNotABackupIsRefusedWithAMessage() throws {
        XCTAssertThrowsError(try Backup.decode(Data("[]".utf8))) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        XCTAssertThrowsError(try Backup.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        XCTAssertThrowsError(try Backup.decode(Data(#"{"format":"something-else","version":1}"#.utf8))) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        XCTAssertThrowsError(try Backup.decode(Data(#"{"format":"mazemaze-backup","version":99}"#.utf8))) { XCTAssertEqual($0 as? BackupError, .newerVersion) }
        XCTAssertThrowsError(try Backup.decode(Data(#"{"format":"mazemaze-backup","version":0}"#.utf8))) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        XCTAssertThrowsError(try Backup.decode(Data(#"{"format":"mazemaze-backup","version":1,"dictionary":5}"#.utf8))) { XCTAssertEqual($0 as? BackupError, .unreadable) }
        XCTAssertThrowsError(try Backup.decode(Data(count: BackupFile.maxBytes + 1))) { XCTAssertEqual($0 as? BackupError, .tooLarge) }
        for e in [BackupError.tooLarge, .notABackup, .newerVersion, .unreadable] { XCTAssertFalse(e.message.isEmpty) }
    }

    // ---- merging
    func testMergeAddsOnlyWhatIsNew_andKeepsDatesAndOrder() {
        var d = dictionary([entry("good weather", "良い天気", at: 300)])
        var b = BookmarkData(); var hosts = ["news.yahoo.co.jp"]
        let incoming = dictionary([entry("good weather", "良い天気", at: 50), entry("take a stroll", "散歩する", at: 400), entry("by the way", "ところで", at: 100)])
        let r = Backup.merge(Backup.make(dictionary: incoming, favorites: [], allowedHosts: []), into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(r.dictionaryAdded, 2); XCTAssertEqual(r.dictionaryDuplicates, 1)
        XCTAssertEqual(d.entries.map(\.english), ["take a stroll", "good weather", "by the way"], "newest first by the saved date")
        XCTAssertEqual(d.entries.first { $0.english == "good weather" }?.savedAt, Date(timeIntervalSince1970: 300), "the existing entry is untouched")
    }

    func testMergingTwiceChangesNothingTheSecondTime() {
        var d = DictionaryData(); var b = BookmarkData(); var hosts: [String] = []
        let file = Backup.make(dictionary: dictionary([entry("a good day", "いい日", at: 1), entry("see you", "またね", at: 2)]),
                               favorites: [SavedSite(title: "Y", url: URL(string: "https://news.yahoo.co.jp/")!)], allowedHosts: ["example.jp"])
        _ = Backup.merge(file, into: &d, bookmarks: &b, allowedHosts: &hosts)
        let after = (d, b, hosts)
        let second = Backup.merge(file, into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(second.dictionaryAdded, 0); XCTAssertEqual(second.favoritesAdded, 0); XCTAssertEqual(second.hostsAdded, 0)
        XCTAssertEqual(d, after.0); XCTAssertEqual(b, after.1); XCTAssertEqual(hosts, after.2)
    }

    func testADuplicateWithACardGivesItsCardToAnEntryWithout() {
        var d = dictionary([entry("have", "持つ", at: 10, kind: .word)])
        var b = BookmarkData(); var hosts: [String] = []
        _ = Backup.merge(Backup.make(dictionary: dictionary([entry("have", "持つ", at: 10, kind: .word, card: card("持つ"))]), favorites: [], allowedHosts: []), into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(d.entries.count, 1); XCTAssertNotNil(d.entries[0].card)
    }

    func testEveryImportedEntryIsCheckedLikeOneAddedByHand() {
        var tooLong = entry("x", "y", at: 5); tooLong.english = String(repeating: "a", count: 301)
        var dirty = entry("clean\u{202E}me\u{0} up", "きれいに\u{200B}する", at: 6, note: "note\u{0}with\u{7}control")
        dirty.sourceURL = URL(string: "https://news.yahoo.co.jp/articles/a?token=SECRET")
        var empty = entry("", "x", at: 7); empty.english = "  "
        let hostile = BackupFile(format: BackupFile.formatName, version: 1, createdAt: Date(), dictionary: dictionaryUnchecked([tooLong, dirty, empty]), favorites: [], allowedHosts: [])
        var d = DictionaryData(); var b = BookmarkData(); var hosts: [String] = []
        let r = Backup.merge(hostile, into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(r.dictionaryAdded, 1); XCTAssertEqual(r.dictionarySkipped, 2)
        let e = d.entries[0]
        XCTAssertFalse(e.english.unicodeScalars.contains { $0.value == 0 || $0.value == 0x202E }); XCTAssertFalse(e.japanese.contains("\u{200B}"))
        XCTAssertFalse(e.note.unicodeScalars.contains { $0.value == 0 || $0.value == 7 })
        XCTAssertFalse((e.sourceURL?.absoluteString ?? "").contains("SECRET"), "a query that could hold a credential is not kept")
    }

    /// A dictionary built from raw JSON (the way a hand-edited file would arrive), bypassing the checks of `add`.
    func dictionaryUnchecked(_ entries: [DictionaryEntry]) -> DictionaryData {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let list = String(data: try! e.encode(entries), encoding: .utf8)!
        return try! JSONDecoder.dictionary.decode(DictionaryData.self, from: Data(#"{"version":2,"entries":\#(list)}"#.utf8))
    }

    func testAFullBackupComesInQuickly() {
        let big = dictionary((0..<DictionaryData.maxEntries).map { entry("word number \($0)", "言葉\($0)", at: TimeInterval($0)) })
        var d = DictionaryData(); var b = BookmarkData(); var hosts: [String] = []
        let started = Date()
        let r = Backup.merge(Backup.make(dictionary: big, favorites: [], allowedHosts: []), into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(r.dictionaryAdded, DictionaryData.maxEntries)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "one index for the whole batch, not a scan per entry")
        XCTAssertEqual(Backup.merge(Backup.make(dictionary: big, favorites: [], allowedHosts: []), into: &d, bookmarks: &b, allowedHosts: &hosts).dictionaryDuplicates, DictionaryData.maxEntries)
    }

    func testTheDictionaryLimitIsRespected() {
        var d = DictionaryData()
        _ = d.merge((0..<DictionaryData.maxEntries).map { entry("word number \($0)", "言葉\($0)", at: TimeInterval($0)) })
        XCTAssertEqual(d.entries.count, DictionaryData.maxEntries)
        var b = BookmarkData(); var hosts: [String] = []
        let r = Backup.merge(Backup.make(dictionary: dictionary([entry("one more", "もう一つ", at: 99_999)]), favorites: [], allowedHosts: []), into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(r.dictionarySkipped, 1); XCTAssertEqual(d.entries.count, DictionaryData.maxEntries)
    }

    func testFavoritesAndHostsAreCheckedToo() {
        let sites = [SavedSite(title: "ok", url: URL(string: "https://news.yahoo.co.jp/")!),
                     SavedSite(title: "plain http", url: URL(string: "http://example.com/")!),
                     SavedSite(title: "credential", url: URL(string: "https://example.com/a?token=abc")!),
                     SavedSite(title: "login", url: URL(string: "https://example.com/login")!),
                     SavedSite(title: "lan", url: URL(string: "https://192.168.0.1/")!)]
        var d = DictionaryData(); var b = BookmarkData(); var hosts = ["news.yahoo.co.jp"]
        let r = Backup.merge(Backup.make(dictionary: DictionaryData(), favorites: sites, allowedHosts: ["example.jp", "com", "192.168.0.1", "localhost", "x.com", "NEWS.yahoo.co.jp", "a b.jp", "evil.co.jp."]),
                             into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(b.favorites.map(\.title), ["ok"]); XCTAssertEqual(r.favoritesAdded, 1); XCTAssertEqual(r.favoritesSkipped, 4)
        XCTAssertEqual(Set(hosts), ["news.yahoo.co.jp", "example.jp", "x.com", "evil.co.jp"])
        XCTAssertEqual(r.hostsAdded, 3)
    }

    func testTheReportSaysWhatHappened() {
        var r = ImportReport(); r.dictionaryAdded = 3; r.dictionaryDuplicates = 2; r.dictionarySkipped = 1; r.favoritesAdded = 1; r.hostsAdded = 4
        XCTAssertTrue(r.summary.contains("3 件を追加")); XCTAssertTrue(r.summary.contains("2 件は")); XCTAssertTrue(r.summary.contains("上限"))
    }
}

final class SnapshotTests: XCTestCase {
    func tmp() -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("mz-snap-\(UUID().uuidString)"); try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }

    func write(_ file: URL, entries: Int) {
        var d = DictionaryData()
        for i in 0..<entries { _ = d.add(english: "word number \(i)", japanese: "言葉\(i)", source: "x.com", sourceURL: nil) }
        XCTAssertTrue(DictionaryStorage(fileURL: file).save(d))
    }

    func date(_ day: Int, hour: Int = 9) -> Date { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }

    func setup(entries: Int = 3) -> (dir: URL, file: URL, snaps: DictionarySnapshots) {
        let dir = tmp(); let file = dir.appendingPathComponent("mazemaze-dictionary.json")
        if entries > 0 { write(file, entries: entries) }
        return (dir, file, DictionarySnapshots(directory: dir.appendingPathComponent("Backups")))
    }

    func testOneDailyCopyAtMost_andNothingForAnEmptyOrMissingDictionary() {
        let (dir, file, snaps) = setup(entries: 0); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(snaps.snapshot(of: file, now: date(1)), .notNeeded)                        // no file
        write(file, entries: 0); XCTAssertEqual(snaps.snapshot(of: file, now: date(1)), .notNeeded)   // empty
        write(file, entries: 3)
        XCTAssertEqual(snaps.snapshot(of: file, now: date(1, hour: 9)), .copied)
        XCTAssertEqual(snaps.snapshot(of: file, now: date(1, hour: 18)), .notNeeded, "once a day")
        XCTAssertEqual(snaps.snapshot(of: file, now: date(2)), .copied)
        XCTAssertEqual(snaps.list().map(\.entryCount), [3, 3]); XCTAssertEqual(snaps.list().first?.date, date(2))
    }

    func testDailyAndBeforeCopiesAreCountedApart() {
        let (dir, file, snaps) = setup(entries: 2); defer { try? FileManager.default.removeItem(at: dir) }
        for day in 1...12 { snaps.snapshot(of: file, now: date(day)) }
        XCTAssertEqual(snaps.list(counts: false).filter { !$0.isBeforeCopy }.count, DictionarySnapshots.keepDaily)
        for i in 0..<6 { XCTAssertEqual(snaps.snapshot(of: file, now: date(12, hour: 10 + i), label: "before-import"), .copied) }
        let all = snaps.list(counts: false)
        XCTAssertEqual(all.filter(\.isBeforeCopy).count, DictionarySnapshots.keepBefore)
        XCTAssertEqual(all.filter { !$0.isBeforeCopy }.count, DictionarySnapshots.keepDaily, "imports never push the daily copies out")
        XCTAssertEqual(all.filter { !$0.isBeforeCopy }.last?.date, date(12 - DictionarySnapshots.keepDaily + 1))
    }

    func testTwoCopiesInTheSameSecondDoNotOverwriteEachOther() {
        let (dir, file, snaps) = setup(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(snaps.snapshot(of: file, now: date(1), label: "before-import"), .copied)
        XCTAssertEqual(snaps.snapshot(of: file, now: date(1), label: "before-import"), .copied)
        XCTAssertEqual(snaps.list(counts: false).count, 2)
    }

    func testRestoringTheOldestCopyNeverLosesIt() {
        let (dir, file, snaps) = setup(entries: 5); defer { try? FileManager.default.removeItem(at: dir) }
        for day in 1...DictionarySnapshots.keepDaily { snaps.snapshot(of: file, now: date(day)) }
        write(file, entries: 1)
        let oldest = snaps.list().last!
        XCTAssertEqual(oldest.date, date(1))
        XCTAssertEqual(snaps.restore(oldest, to: file, currentFileIsWritable: true, now: date(20)), .restored(entries: 5))
        XCTAssertEqual(DictionaryStorage(fileURL: file).load().entries.count, 5)
        XCTAssertTrue(snaps.list(counts: false).contains { $0.isBeforeCopy }, "the dictionary that was replaced is kept")
    }

    func testRestoreChecksEverythingBeforeReplacingAnything() throws {
        let (dir, file, snaps) = setup(entries: 4); defer { try? FileManager.default.removeItem(at: dir) }
        snaps.snapshot(of: file, now: date(1))
        let good = snaps.list().first!
        // the dictionary file cannot be read: protected
        XCTAssertEqual(snaps.restore(good, to: file, currentFileIsWritable: false), .refusedBecauseUnwritable)
        try Data("{ broken".utf8).write(to: file)
        XCTAssertEqual(snaps.restore(good, to: file, currentFileIsWritable: true), .refusedBecauseUnwritable)
        XCTAssertEqual(try Data(contentsOf: file), Data("{ broken".utf8), "the unreadable file is untouched")
        write(file, entries: 2)
        // a damaged copy, a copy from a newer version
        let bad = dir.appendingPathComponent("Backups/dictionary-20261003-090000.json"); try Data("garbage".utf8).write(to: bad)
        XCTAssertEqual(snaps.restore(.init(url: bad, date: date(3), entryCount: -1), to: file, currentFileIsWritable: true), .unreadableCopy)
        let newer = dir.appendingPathComponent("Backups/dictionary-20261004-090000.json")
        try Data(#"{"version":99,"entries":[]}"#.utf8).write(to: newer)
        XCTAssertEqual(snaps.restore(.init(url: newer, date: date(4), entryCount: 0), to: file, currentFileIsWritable: true), .unreadableCopy)
        XCTAssertEqual(DictionaryStorage(fileURL: file).load().entries.count, 2, "nothing was replaced by any of these")
    }

    func testIfTheCurrentDictionaryCannotBeKeptNothingIsReplaced() throws {
        let (dir, file, snaps) = setup(entries: 4); defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("Backups").path); try? FileManager.default.removeItem(at: dir) }
        snaps.snapshot(of: file, now: date(1))
        let good = snaps.list().first!
        write(file, entries: 2)
        // the folder for copies can still be read but not written to (a full disk, a failing write): the safety copy cannot be made
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.appendingPathComponent("Backups").path)
        XCTAssertEqual(snaps.snapshot(of: file, now: date(2), label: "before-x"), .failed)
        XCTAssertEqual(snaps.restore(good, to: file, currentFileIsWritable: true, now: date(3)), .couldNotKeepCurrent)
        XCTAssertEqual(DictionaryStorage(fileURL: file).load().entries.count, 2, "the dictionary was not replaced without a copy of it")
    }

    func testFilesSetAsideBecauseTheyCouldNotBeReadAreListed() throws {
        let (dir, file, _) = setup(entries: 0); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ broken".utf8).write(to: file)
        let storage = DictionaryStorage(fileURL: file)
        XCTAssertEqual(storage.load().entries.count, 0)
        XCTAssertNotNil(storage.lastLoadProblem)
        XCTAssertEqual(storage.asideFiles().count, 1)
        XCTAssertTrue(storage.asideFiles()[0].lastPathComponent.hasPrefix("mazemaze-dictionary.unreadable-"))
        XCTAssertEqual(try Data(contentsOf: storage.asideFiles()[0]), Data("{ broken".utf8), "the original bytes are kept")
    }
}

final class ImportSafetyTests: XCTestCase {
    func site(_ t: String, _ u: String) -> SavedSite { SavedSite(title: t, url: URL(string: u)!) }

    func testImportedFavoritesNeverPushOutExistingOnes() {
        var b = BookmarkData()
        for i in 0..<30 { XCTAssertTrue(b.addFavorite(url: URL(string: "https://example\(i).jp/")!, title: "mine \(i)")) }
        let existing = Set(b.favorites.map(\.title))
        let incoming = (0..<40).map { site("theirs \($0)", "https://other\($0).jp/") }
        var d = DictionaryData(); var hosts: [String] = []
        let r = Backup.merge(Backup.make(dictionary: DictionaryData(), favorites: incoming, allowedHosts: []), into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertEqual(b.favorites.count, Favorites.maxFavorites)
        XCTAssertTrue(existing.isSubset(of: Set(b.favorites.map(\.title))), "all 30 of mine are still there")
        XCTAssertEqual(r.favoritesAdded, 10); XCTAssertEqual(r.favoritesSkipped, 30)
        XCTAssertEqual(b.favorites.prefix(10).map(\.title), (0..<10).map { "theirs \($0)" }, "the newest of the file came in, in order")
    }

    func testCardsFromAFileAreHeldToTheLimitsOfAModelsCard() {
        let huge = String(repeating: "あ", count: 100_000)
        let bad = DefinitionCard.word(WordCard(lemma: "have", pos: "動詞", contextMeaning: huge, contextIndex: 0, meanings: [WordMeaning(meaning: huge)], matchInSource: nil, phrases: [], note: nil))
        XCTAssertNil(bad.revalidated(), "an unusable card is dropped")
        let heavy = DefinitionCard.word(WordCard(lemma: "have", pos: "動詞", contextMeaning: "持つ", contextIndex: 7,
                                                 meanings: (0..<20).map { WordMeaning(meaning: "意味\($0)", exampleEn: huge, exampleJa: huge) },
                                                 matchInSource: huge, phrases: (0..<50).map { "phrase \($0)" }, note: huge))
        guard case .word(let c)? = heavy.revalidated() else { return XCTFail() }
        XCTAssertLessThanOrEqual(c.meanings.count, 5); XCTAssertLessThanOrEqual(c.phrases.count, 4); XCTAssertNil(c.note); XCTAssertNil(c.matchInSource)
        XCTAssertTrue(c.meanings.allSatisfy { $0.exampleEn == nil }); XCTAssertTrue(c.meanings.indices.contains(c.contextIndex))
        let evil = DefinitionCard.phrase(PhraseCard(meaning: "ok\u{202E}evil", nuance: nil, points: [], synonyms: [], examples: []))
        XCTAssertNil(evil.revalidated(), "invisible direction characters are refused, never repaired")
        XCTAssertNotNil(DefinitionCard.phrase(PhraseCard(meaning: "昼食をとる", nuance: "くだけた", points: [], synonyms: ["eat lunch"], examples: [])).revalidated())
        // through a whole entry: the entry stays, the bad card goes
        let e = DictionaryEntry(kind: .word, english: "have", japanese: "持つ", source: "x.com", sourceURL: nil, savedAt: Date(), card: bad)
        var d = DictionaryData(); _ = d.merge(e)
        XCTAssertEqual(d.entries.count, 1); XCTAssertNil(d.entries[0].card)
    }

    func testSensitiveHostsAreNotImported() {
        var d = DictionaryData(); var b = BookmarkData(); var hosts: [String] = []
        let r = Backup.merge(Backup.make(dictionary: DictionaryData(), favorites: [], allowedHosts: ["news.example.jp", "login.example.jp", "accounts.example.jp", "mail.example.jp", "bank.example.jp", "auth.example.jp"]),
                             into: &d, bookmarks: &b, allowedHosts: &hosts)
        XCTAssertTrue(hosts.contains("news.example.jp"))
        XCTAssertFalse(hosts.contains("login.example.jp")); XCTAssertFalse(hosts.contains("accounts.example.jp")); XCTAssertFalse(hosts.contains("auth.example.jp"))
        XCTAssertEqual(r.hostsAdded, hosts.count)
    }
}

final class ProvisioningProfileTests: XCTestCase {
    func profile(expiry: Date) -> Data {
        let plist = try! PropertyListSerialization.data(fromPropertyList: ["Name": "iOS Team Provisioning Profile", "ExpirationDate": expiry], format: .xml, options: 0)
        var d = Data([0x30, 0x82, 0x01, 0x00, 0xFF, 0xFE])        // the signed wrapper around it
        d.append(plist); d.append(Data([0x00, 0x01, 0x02, 0xAA]))
        return d
    }

    func testTheExpiryIsFoundInsideTheSignedWrapper() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ProvisioningProfile.expirationDate(from: profile(expiry: expiry)), expiry)
    }

    func testNoProfileOrAnUnreadableOneGivesNil() {
        XCTAssertNil(ProvisioningProfile.expirationDate(from: Data()))
        XCTAssertNil(ProvisioningProfile.expirationDate(from: Data("no plist here".utf8)))
        XCTAssertNil(ProvisioningProfile.expirationDate(from: Data("<?xml broken </plist>".utf8)))
        let noDate = try! PropertyListSerialization.data(fromPropertyList: ["Name": "x"], format: .xml, options: 0)
        XCTAssertNil(ProvisioningProfile.expirationDate(from: noDate))
    }

    func testDaysLeftRoundsDownAndIsNeverNegative() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ProvisioningProfile.daysLeft(until: now.addingTimeInterval(6.5 * 86_400), now: now), 6)
        XCTAssertEqual(ProvisioningProfile.daysLeft(until: now.addingTimeInterval(3_600), now: now), 0)
        XCTAssertEqual(ProvisioningProfile.daysLeft(until: now.addingTimeInterval(-86_400), now: now), 0)
    }
}

final class EngineCheckTests: XCTestCase {
    let items = [EngineCheckItem(id: "a", category: "x", text: "今日は天気がいいので、散歩に行きました。"), EngineCheckItem(id: "b", category: "y", text: "友達と一緒に新しいカフェで朝ごはんを食べた。")]

    func testItRunsEveryTextAndSummarizes() async throws {
        let engine = FakeSpanEngine()
        let results = try await EngineCheck.run(items: items, engine: engine, ratio: 0.5, unit: .phrase)
        XCTAssertEqual(results.map(\.id), ["a", "b"])
        XCTAssertTrue(results.allSatisfy { $0.preserved && $0.error == nil && $0.acceptedSpans > 0 })
        let s = EngineCheck.summarize(results)
        XCTAssertTrue(s.preservedAll); XCTAssertEqual(s.texts, 2); XCTAssertEqual(s.errors, 0); XCTAssertEqual(s.acceptedSpans, s.requestedSpans)
        XCTAssertTrue(s.text.contains("すべて一致"))
    }

    func testAFailingEngineIsReportedPerTextAndTheOriginalIsKept() async throws {
        let engine = FakeSpanEngine { _, _ in throw EngineError.unavailable("オンにしてください") }
        let results = try await EngineCheck.run(items: items, engine: engine, ratio: 0.5, unit: .phrase)
        XCTAssertTrue(results.allSatisfy { $0.error == "オンにしてください" && $0.mixed == items[results.firstIndex(of: $0)!].text })
        XCTAssertEqual(EngineCheck.summarize(results).errors, 2)
    }

    func testAnEngineThatInventsTextIsStillPreserved() async throws {
        let engine = FakeSpanEngine { _, spans in Dictionary(uniqueKeysWithValues: spans.map { ($0.id, "Hello\n") }) }
        let results = try await EngineCheck.run(items: items, engine: engine, ratio: 0.7, unit: .phrase)
        XCTAssertTrue(EngineCheck.summarize(results).preservedAll)
    }

    func testItsItemsLoadFromJSON() {
        let json = #"[{"id":"k1","category":"keigo","text":"お忙しいところ恐れ入ります。"}]"#
        XCTAssertEqual(EngineCheck.items(from: Data(json.utf8)).map(\.id), ["k1"])
        XCTAssertEqual(EngineCheck.items(from: Data("nope".utf8)), [])
    }
}
