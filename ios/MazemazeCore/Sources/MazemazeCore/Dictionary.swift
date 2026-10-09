import Foundation

/// One saved expression: the English the page showed and the Japanese it replaced (the original).
/// Only what the person chose to save, only on this iPhone.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var english: String
    public var japanese: String
    /// "x.com", "news.yahoo.co.jp", or "貼り付け" for the paste screen.
    public var source: String
    /// The page it came from, only when it is a public page (SessionPrivacy decides; never a query or a login page).
    public var sourceURL: URL?
    public var note: String
    public var savedAt: Date

    public init(id: UUID = UUID(), english: String, japanese: String, source: String, sourceURL: URL?, note: String = "", savedAt: Date) {
        self.id = id; self.english = english; self.japanese = japanese; self.source = source
        self.sourceURL = sourceURL; self.note = note; self.savedAt = savedAt
    }
}

/// The dictionary: newest first, no duplicates, bounded. A plain value (loading and saving live in DictionaryStorage).
public struct DictionaryData: Codable, Equatable, Sendable {
    public static let currentVersion = 1
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

    @discardableResult
    public mutating func add(english: String, japanese: String, source: String, sourceURL: URL?, now: Date = Date()) -> AddResult {
        let en = Self.clean(english), ja = Self.clean(japanese)
        guard !en.isEmpty, !ja.isEmpty else { return .rejected(.empty) }
        guard en.unicodeScalars.count <= Self.maxTermScalars, ja.unicodeScalars.count <= Self.maxTermScalars else { return .rejected(.tooLong) }
        let k = Self.key(en, ja)
        if let existing = entries.first(where: { Self.key($0.english, $0.japanese) == k }) { return .duplicate(existing) }
        guard entries.count < Self.maxEntries else { return .rejected(.full) }
        let src = Self.clean(source)
        let entry = DictionaryEntry(english: en, japanese: ja, source: String(src.prefix(80)),
                                    sourceURL: SessionPrivacy.persistableURL(sourceURL), savedAt: now)
        entries.insert(entry, at: 0)
        return .added(entry)
    }

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
            let hay = [e.english, e.japanese, e.note, e.source].joined(separator: "\n").lowercased()
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
        var rows = ["english,japanese,source,url,note,saved_at"]
        for e in entries {
            rows.append([cell(e.english), cell(e.japanese), cell(e.source), cell(e.sourceURL?.absoluteString ?? ""), cell(e.note), iso.string(from: e.savedAt)].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// One line per entry: "english — japanese".
    public func plainText() -> String { entries.map { "\($0.english) — \($0.japanese)" }.joined(separator: "\n") }
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
        if let d = try? decoder.decode(DictionaryData.self, from: data), d.version <= DictionaryData.currentVersion { return d }
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
