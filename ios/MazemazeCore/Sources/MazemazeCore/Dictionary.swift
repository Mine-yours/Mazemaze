import Foundation

/// One saved expression: the English the page showed and the Japanese it replaced (the original).
/// Only what the person chose to save, only on this iPhone.
public enum EntryKind: String, Codable, Equatable, Sendable { case expression, word }

/// A word saved from the dictionary tab has no meaning yet: the app looks it up in the background.
public enum MeaningState: String, Codable, Equatable, Sendable { case none, pending, failed }

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// `.expression`: a span of the page (English + the Japanese it replaced). `.word`: one word with its sense.
    public var kind: EntryKind
    public var english: String
    /// An expression: the Japanese it replaced. A word: its meaning in this sentence (empty while `meaning == .pending`).
    public var japanese: String
    /// Where a word was read: the English phrase on the page and the Japanese it replaced (empty for expressions, which are these).
    public var contextEnglish: String
    public var contextJapanese: String
    public var meaning: MeaningState
    /// "x.com", "news.yahoo.co.jp", or "貼り付け" for the paste screen.
    public var source: String
    /// The page it came from, only when it is a public page (SessionPrivacy decides; never a query or a login page).
    public var sourceURL: URL?
    public var note: String
    public var savedAt: Date
    /// The meaning card the local model made (word senses / phrase explanation), if the person looked it up.
    public var card: DefinitionCard?

    public init(id: UUID = UUID(), kind: EntryKind = .expression, english: String, japanese: String, contextEnglish: String = "", contextJapanese: String = "",
                meaning: MeaningState = .none, source: String, sourceURL: URL?, note: String = "", savedAt: Date, card: DefinitionCard? = nil) {
        self.id = id; self.kind = kind; self.english = english; self.japanese = japanese
        self.contextEnglish = contextEnglish; self.contextJapanese = contextJapanese; self.meaning = meaning
        self.source = source; self.sourceURL = sourceURL; self.note = note; self.savedAt = savedAt; self.card = card
    }

    private enum CodingKeys: String, CodingKey { case id, kind, english, japanese, contextEnglish, contextJapanese, meaning, source, sourceURL, note, savedAt, card }

    public init(from decoder: Decoder) throws {          // files saved before words and cards existed have no kind / card
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(EntryKind.self, forKey: .kind) ?? .expression
        english = try c.decode(String.self, forKey: .english)
        japanese = try c.decode(String.self, forKey: .japanese)
        contextEnglish = try c.decodeIfPresent(String.self, forKey: .contextEnglish) ?? ""
        contextJapanese = try c.decodeIfPresent(String.self, forKey: .contextJapanese) ?? ""
        meaning = (try? c.decodeIfPresent(MeaningState.self, forKey: .meaning)) ?? .none
        source = try c.decode(String.self, forKey: .source)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        card = try? c.decodeIfPresent(DefinitionCard.self, forKey: .card)       // an unreadable card never loses the entry
    }
}

/// The dictionary: newest first, no duplicates, bounded. A plain value (loading and saving live in DictionaryStorage).
public struct DictionaryData: Codable, Equatable, Sendable {
    public static let currentVersion = 2      // 2: entries may be words and may carry a meaning card (version-1 files still load)
    public static let maxEntries = 5000
    public static let maxTermScalars = 300
    public static let maxNoteScalars = 1000
    public static let pasteSource = "貼り付け"

    public var version = DictionaryData.currentVersion
    public private(set) var entries: [DictionaryEntry] = []

    public init() {}

    public enum Rejection: Equatable, Sendable {
        case empty, tooLong, full
        public var message: String {
            switch self {
            case .empty: return "保存する内容がありません。"
            case .tooLong: return "長すぎるため保存できません（\(DictionaryData.maxTermScalars) 文字まで）。"
            case .full: return "辞書がいっぱいです（\(DictionaryData.maxEntries) 件まで）。使わないものを削除してください。"
            }
        }
    }

    public enum AddResult: Equatable, Sendable {
        case added(DictionaryEntry)
        case duplicate(DictionaryEntry)      // already saved: nothing changes
        case rejected(Rejection)
    }

    /// Control characters out, line breaks and runs of spaces folded to one space, ends trimmed.
    static func clean(_ s: String) -> String {
        // Control characters become spaces; invisible format characters (direction overrides, zero-width spaces, ...)
        // are dropped, except the zero-width joiner that emoji sequences need.
        let scalars: [Unicode.Scalar] = s.unicodeScalars.compactMap { sc in
            if sc.properties.generalCategory == .control || sc == "\u{2028}" || sc == "\u{2029}" { return " " }
            if sc.properties.generalCategory == .format && sc != "\u{200D}" { return nil }
            return sc
        }
        var out = ""
        var lastSpace = false
        for sc in scalars {
            let isSpace = sc == " " || sc == "\u{3000}" || sc == "\u{A0}"
            if isSpace { if !lastSpace { out.unicodeScalars.append(" ") }; lastSpace = true }
            else { out.unicodeScalars.append(sc); lastSpace = false }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func key(_ english: String, _ japanese: String) -> String {
        english.precomposedStringWithCanonicalMapping.lowercased() + "\u{0}" + japanese.precomposedStringWithCanonicalMapping
    }

    /// What makes two entries "the same": an expression is its English and Japanese; a word is the word in the sentence it was read in.
    static func key(of e: DictionaryEntry) -> String { e.kind == .word && !e.contextJapanese.isEmpty ? key(e.english, e.contextJapanese) : key(e.english, e.japanese) }

    @discardableResult
    public mutating func add(english: String, japanese: String, source: String, sourceURL: URL?, now: Date = Date(),
                             kind: EntryKind = .expression, card: DefinitionCard? = nil,
                             contextEnglish: String = "", contextJapanese: String = "", meaning: MeaningState = .none) -> AddResult {
        let en = Self.clean(english), ja = Self.clean(japanese)
        let ctxEn = Self.clean(contextEnglish), ctxJa = Self.clean(contextJapanese)
        guard !en.isEmpty, !ja.isEmpty || meaning == .pending else { return .rejected(.empty) }       // a pending word has no meaning yet
        guard [en, ja, ctxEn, ctxJa].allSatisfy({ $0.unicodeScalars.count <= Self.maxTermScalars }) else { return .rejected(.tooLong) }
        let src = Self.clean(source)
        let entry = DictionaryEntry(kind: kind, english: en, japanese: ja, contextEnglish: ctxEn, contextJapanese: ctxJa, meaning: meaning,
                                    source: String(src.prefix(80)), sourceURL: SessionPrivacy.persistableURL(sourceURL), savedAt: now, card: card)
        let k = Self.key(of: entry)
        if let existing = entries.first(where: { Self.key(of: $0) == k }) { return .duplicate(existing) }
        guard entries.count < Self.maxEntries else { return .rejected(.full) }
        entries.insert(entry, at: 0)
        return .added(entry)
    }

    /// A word looked up on the card: saved as its own entry (English = base form, Japanese = the sense in context), with the
    /// English phrase and the Japanese original it was read in.
    @discardableResult
    public mutating func addWord(_ card: WordCard, contextEnglish: String = "", contextJapanese: String = "", source: String, sourceURL: URL?, now: Date = Date()) -> AddResult {
        add(english: card.lemma, japanese: card.contextMeaning, source: source, sourceURL: sourceURL, now: now, kind: .word, card: .word(card),
            contextEnglish: contextEnglish, contextJapanese: contextJapanese)
    }

    /// A word saved straight from the iPhone's dictionary: its meaning is looked up in the background afterwards.
    @discardableResult
    public mutating func addPendingWord(_ term: String, contextEnglish: String, contextJapanese: String, source: String, sourceURL: URL?, now: Date = Date()) -> AddResult {
        add(english: term, japanese: "", source: source, sourceURL: sourceURL, now: now, kind: .word, card: nil,
            contextEnglish: contextEnglish, contextJapanese: contextJapanese, meaning: .pending)
    }

    /// Attach (or replace) the meaning card of an entry that already exists. A word takes the sense in context as its meaning.
    public mutating func setCard(id: UUID, card: DefinitionCard) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].card = card
        if entries[i].kind == .word, case .word(let c) = card { entries[i].japanese = c.contextMeaning }
        entries[i].meaning = .none
    }

    public mutating func setMeaningState(id: UUID, _ state: MeaningState) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].card == nil else { return }
        entries[i].meaning = state
    }

    /// Words waiting for their meaning, oldest first (the order they were saved in).
    public var pendingWords: [DictionaryEntry] { entries.filter { $0.kind == .word && $0.meaning == .pending && $0.card == nil }.reversed() }

    public mutating func remove(id: UUID) { entries.removeAll { $0.id == id } }
    public mutating func remove(ids: Set<UUID>) { entries.removeAll { ids.contains($0.id) } }

    public mutating func setNote(id: UUID, note: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var n = String(note.unicodeScalars.filter { $0.properties.generalCategory != .control || $0 == "\n" }.map(Character.init))
        if n.unicodeScalars.count > Self.maxNoteScalars { n = String(String.UnicodeScalarView(n.unicodeScalars.prefix(Self.maxNoteScalars))) }
        entries[i].note = n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Entries whose English, Japanese, note or source contain every word of the query (case-insensitive).
    public func search(_ query: String) -> [DictionaryEntry] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in
            let hay = [e.english, e.japanese, e.contextEnglish, e.contextJapanese, e.note, e.source, e.card?.searchText ?? ""].joined(separator: "\n").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    public func contains(english: String, japanese: String) -> Bool {
        let k = Self.key(Self.clean(english), Self.clean(japanese))
        return entries.contains { Self.key($0.english, $0.japanese) == k }
    }

    // MARK: export
    /// RFC 4180 CSV (UTF-8). A cell that a spreadsheet could read as a formula gets a leading apostrophe.
    public func csv() -> String {
        func cell(_ s: String) -> String {
            var v = s
            if let f = v.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(f) { v = "'" + v }
            if v.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) { v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return v
        }
        let iso = ISO8601DateFormatter()
        var rows = ["english,japanese,type,details,context_en,context_ja,source,url,note,saved_at"]
        for e in entries {
            rows.append([cell(e.english), cell(e.japanese), e.kind.rawValue, cell(e.card?.details ?? ""), cell(e.contextEnglish), cell(e.contextJapanese),
                         cell(e.source), cell(e.sourceURL?.absoluteString ?? ""), cell(e.note), iso.string(from: e.savedAt)].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// One line per entry: "english — japanese".
    public func plainText() -> String { entries.map { "\($0.english) — \($0.japanese.isEmpty ? $0.contextJapanese : $0.japanese)" }.joined(separator: "\n") }
}

/// Loads and saves the dictionary as one JSON file (atomic writes). A file that cannot be read is never replaced:
/// if it is unreadable for now (for example the phone is locked) or cannot be moved aside, saving is refused until
/// it can be read again, so saved words are never silently destroyed.
public final class DictionaryStorage: @unchecked Sendable {
    public let fileURL: URL
    public private(set) var lastLoadProblem: String?
    /// False while the existing file could not be read: `save` refuses, to protect it.
    public private(set) var isWritable = true

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("mazemaze-dictionary.json")
    }

    public func load() -> DictionaryData {
        lastLoadProblem = nil
        isWritable = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return DictionaryData() }
        guard let data = try? Data(contentsOf: fileURL) else {
            isWritable = false
            lastLoadProblem = "辞書のファイルを今は読み込めません（端末のロック中など）。保存した内容を守るため、読み込めるまで新しい保存はしません。"
            return DictionaryData()
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if var d = try? decoder.decode(DictionaryData.self, from: data), d.version <= DictionaryData.currentVersion {
            d.version = DictionaryData.currentVersion          // a version-1 file is written back as version 2
            return d
        }
        let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try fm.moveItem(at: fileURL, to: aside)
            lastLoadProblem = "辞書のファイルを読み込めませんでした。元のファイルは \(aside.lastPathComponent) として残してあります。"
        } catch {
            isWritable = false
            lastLoadProblem = "辞書のファイルを読み込めず、退避もできませんでした。保存した内容を守るため、新しい保存はしません。"
        }
        return DictionaryData()
    }

    @discardableResult
    public func save(_ data: DictionaryData) -> Bool {
        guard isWritable else { return false }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(data) else { return false }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        do { try bytes.write(to: fileURL, options: options); return true } catch { return false }
    }
}
