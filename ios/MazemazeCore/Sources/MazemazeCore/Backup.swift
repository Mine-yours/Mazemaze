import Foundation

/// A backup the person writes out and brings back by hand (Files, iCloud Drive, AirDrop, ...). Nothing is sent anywhere by the
/// app: this is just a file. It holds what is worth keeping: the dictionary (with meaning cards and the context words were read in),
/// the favorites and the sites translation is allowed on. Settings and history are not part of it.
public struct BackupFile: Codable, Equatable, Sendable {
    public static let formatName = "mazemaze-backup"
    public static let currentVersion = 1
    public static let maxBytes = 30_000_000

    public var format: String
    public var version: Int
    public var createdAt: Date
    public var dictionary: DictionaryData
    public var favorites: [SavedSite]
    public var allowedHosts: [String]
}

public enum BackupError: Error, Equatable, Sendable {
    case tooLarge, notABackup, newerVersion, unreadable

    public var message: String {
        switch self {
        case .tooLarge: return "ファイルが大きすぎるため、取り込めません。"
        case .notABackup: return "Mazemaze のバックアップのファイルではありません。"
        case .newerVersion: return "新しい版のアプリで作られたバックアップです。アプリを更新してから取り込んでください。"
        case .unreadable: return "ファイルを読み取れませんでした（壊れているかもしれません）。"
        }
    }
}

public struct ImportReport: Equatable, Sendable {
    public var dictionaryAdded = 0
    public var dictionaryDuplicates = 0
    public var dictionarySkipped = 0          // rejected (too long, empty) or no room left
    public var favoritesAdded = 0
    public var favoritesSkipped = 0
    public var hostsAdded = 0

    public var summary: String {
        var lines = ["辞書: \(dictionaryAdded) 件を追加（\(dictionaryDuplicates) 件は、すでにあったため追加しません）"]
        if dictionarySkipped > 0 { lines.append("辞書: \(dictionarySkipped) 件は、内容や件数の上限のため取り込めませんでした") }
        lines.append("お気に入り: \(favoritesAdded) 件を追加" + (favoritesSkipped > 0 ? "（\(favoritesSkipped) 件は追加しません）" : ""))
        lines.append("翻訳するサイト: \(hostsAdded) 件を追加")
        return lines.joined(separator: "\n")
    }
}

public enum Backup {
    public static let maxHosts = 200

    /// A site from a backup that may be added to the translation list: a normal host name that is not a login / account / mail-like site.
    public static func importableHost(_ raw: String) -> String? {
        guard let host = SitePolicy.normalizeEntry(raw) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        if labels.contains(where: { SitePolicy.deniedHostLabels.contains($0) || SessionPrivacy.extraSensitiveHostLabels.contains($0) }) { return nil }
        return host
    }

    public static func make(dictionary: DictionaryData, favorites: [SavedSite], allowedHosts: [String], now: Date = Date()) -> BackupFile {
        BackupFile(format: BackupFile.formatName, version: BackupFile.currentVersion, createdAt: now, dictionary: dictionary, favorites: favorites, allowedHosts: allowedHosts)
    }

    public static func encode(_ file: BackupFile) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(file)
    }

    /// Reads a backup file. Never trusts it: size, name and version are checked first; what is inside is checked again on `merge`.
    public static func decode(_ data: Data) throws -> BackupFile {
        guard data.count <= BackupFile.maxBytes else { throw BackupError.tooLarge }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        // Look at the header alone first, so a different kind of JSON file is called what it is.
        struct Header: Decodable { let format: String?; let version: Int? }
        guard let header = try? d.decode(Header.self, from: data), header.format == BackupFile.formatName else { throw BackupError.notABackup }
        guard let v = header.version, v >= 1 else { throw BackupError.notABackup }
        guard v <= BackupFile.currentVersion else { throw BackupError.newerVersion }
        guard let file = try? d.decode(BackupFile.self, from: data) else { throw BackupError.unreadable }
        return file
    }

    /// `decode` as a `Result` (to be run off the main thread).
    public static func decodeResult(_ data: Data) -> Result<BackupFile, BackupError> {
        do { return .success(try decode(data)) } catch { return .failure((error as? BackupError) ?? .unreadable) }
    }

    /// Brings a backup into what is there now: nothing is replaced or removed; duplicates are not added twice. Every entry, site and
    /// host goes through the same checks as one added by hand.
    public static func merge(_ file: BackupFile, into dictionary: inout DictionaryData, bookmarks: inout BookmarkData, allowedHosts: inout [String]) -> ImportReport {
        var report = ImportReport()
        for result in dictionary.merge(file.dictionary.entries) {
            switch result {
            case .added: report.dictionaryAdded += 1
            case .duplicate: report.dictionaryDuplicates += 1
            case .rejected: report.dictionarySkipped += 1
            }
        }
        // Favorites: only into the room that is left (an existing favorite is never pushed out). The newest ones of the file first.
        let room = max(0, Favorites.maxFavorites - bookmarks.favorites.count)
        var candidates: [SavedSite] = []
        for site in file.favorites {
            if bookmarks.isFavorite(site.url) || Favorites.favoriteURL(site.url) == nil { report.favoritesSkipped += 1; continue }
            if candidates.count < room, !candidates.contains(where: { Favorites.dedupeKey($0.url) == Favorites.dedupeKey(site.url) }) { candidates.append(site) } else { report.favoritesSkipped += 1 }
        }
        for site in candidates.reversed() {                                                  // oldest first, so the newest ends up in front
            if bookmarks.addFavorite(url: site.url, title: site.title) { report.favoritesAdded += 1 } else { report.favoritesSkipped += 1 }
        }
        for raw in file.allowedHosts.prefix(maxHosts) {
            guard let host = importableHost(raw), !allowedHosts.contains(host), allowedHosts.count < maxHosts else { continue }
            allowedHosts.append(host); report.hostsAdded += 1
        }
        return report
    }
}

/// Dated copies of the dictionary file, kept inside the app, so a deleted or damaged dictionary can be put back.
/// One daily copy at most (the first start of the day), plus copies taken before an import or a restore. The newest 8 daily copies
/// and the newest 3 "before" copies are kept, counted apart, so a few imports never push the daily copies out.
public struct DictionarySnapshots {
    public struct Snapshot: Equatable, Identifiable, Sendable {
        public let url: URL
        public let date: Date
        public let entryCount: Int            // -1 when not read (see `list(counts:)`)
        public var id: String { url.lastPathComponent }
        public var isBeforeCopy: Bool { url.lastPathComponent.contains("-before-") }
    }

    public enum CopyResult: Equatable, Sendable {
        case copied
        case notNeeded          // nothing worth keeping (no file, empty, unreadable) or today's copy exists
        case failed             // there was something to keep and it could not be written
    }

    public enum RestoreResult: Equatable, Sendable {
        case restored(entries: Int)
        case refusedBecauseUnwritable        // the current dictionary file could not be read: it is protected, nothing is replaced
        case unreadableCopy                  // the copy is damaged or from a newer version
        case couldNotKeepCurrent             // the current dictionary could not be copied first, so nothing is replaced
        case couldNotWrite
    }

    public static let keepDaily = 8
    public static let keepBefore = 3
    public let directory: URL
    private let formatter: DateFormatter

    public init(directory: URL) {
        self.directory = directory
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyyMMdd-HHmmss"
    }

    public static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Backups", isDirectory: true)
    }

    private func isCopy(_ name: String) -> Bool { name.hasPrefix("dictionary-") && name.hasSuffix(".json") }
    private func stamp(of name: String) -> String { String(name.dropFirst("dictionary-".count).prefix(15)) }
    private func name(_ date: Date, _ label: String, _ n: Int) -> String {
        "dictionary-\(formatter.string(from: date))\(label.isEmpty ? "" : "-" + label)\(n > 0 ? "-\(n)" : "").json"
    }
    private func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter(isCopy) }

    /// Copies `file` (`label` "": the daily copy, at most one per day; otherwise an extra copy taken before something risky). An empty,
    /// missing or unreadable dictionary is not worth keeping. `protecting` is never pruned (the copy about to be restored).
    @discardableResult
    public func snapshot(of file: URL, now: Date = Date(), label: String = "", protecting: URL? = nil) -> CopyResult {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: file), Self.count(in: data) > 0 else { return .notNeeded }
        if label.isEmpty {
            let today = formatter.string(from: now).prefix(8)
            if names().contains(where: { !$0.contains("-before-") && stamp(of: $0).prefix(8) == today }) { return .notNeeded }
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var n = 0
            while fm.fileExists(atPath: directory.appendingPathComponent(name(now, label, n)).path) { n += 1 }          // two in the same second never overwrite
            try data.write(to: directory.appendingPathComponent(name(now, label, n)), options: [.atomic])
        } catch { return .failed }
        prune(protecting: protecting)
        return .copied
    }

    /// The copies, newest first. `counts: false` skips reading the files (their names are enough to list or prune them).
    public func list(counts: Bool = true) -> [Snapshot] {
        names().compactMap { n -> Snapshot? in
            guard let date = formatter.date(from: stamp(of: n)) else { return nil }
            let url = directory.appendingPathComponent(n)
            let count = counts ? (try? Data(contentsOf: url)).map(Self.count(in:)) ?? -1 : -1
            return Snapshot(url: url, date: date, entryCount: count)
        }.sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// Puts a copy back as the dictionary file. Everything that could go wrong is checked before anything is replaced: the copy must
    /// read and be of a version this app knows, the current dictionary file must not be one that could not be read, and the current
    /// dictionary is copied first (and that copy must succeed when there is something in it). The copy's bytes are held in memory,
    /// so keeping the current one can never push the copy out.
    public func restore(_ s: Snapshot, to file: URL, currentFileIsWritable: Bool, now: Date = Date()) -> RestoreResult {
        guard currentFileIsWritable else { return .refusedBecauseUnwritable }
        guard let data = try? Data(contentsOf: s.url), let d = try? JSONDecoder.dictionary.decode(DictionaryData.self, from: data), d.version <= DictionaryData.currentVersion else { return .unreadableCopy }
        if FileManager.default.fileExists(atPath: file.path) {
            guard let current = try? Data(contentsOf: file) else { return .refusedBecauseUnwritable }
            let n = Self.count(in: current)
            if n < 0 { return .refusedBecauseUnwritable }                      // a file that cannot be read is never replaced
            if n > 0, snapshot(of: file, now: now, label: "before-restore", protecting: s.url) == .failed { return .couldNotKeepCurrent }
        }
        do {
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            try data.write(to: file, options: [.atomic])
            #endif
        } catch { return .couldNotWrite }
        return .restored(entries: d.entries.count)
    }

    private func prune(protecting: URL?) {
        let all = list(counts: false)
        let daily = all.filter { !$0.isBeforeCopy }, before = all.filter { $0.isBeforeCopy }
        for s in daily.dropFirst(Self.keepDaily) + before.dropFirst(Self.keepBefore) where s.url != protecting { try? FileManager.default.removeItem(at: s.url) }
    }

    static func count(in data: Data) -> Int {
        (try? JSONDecoder.dictionary.decode(DictionaryData.self, from: data))?.entries.count ?? -1
    }
}

extension JSONDecoder {
    static var dictionary: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// When the signature of an app installed with a free Apple ID runs out (7 days after it was installed), read from the profile that
/// Xcode put inside the app. `nil` when there is none (Simulator, App Store) or it cannot be read.
public enum ProvisioningProfile {
    public static func expirationDate(from data: Data) -> Date? {
        // The file is a signed (CMS) wrapper around an XML property list: find the list inside it.
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        guard let obj = try? PropertyListSerialization.propertyList(from: Data(plist), options: [], format: nil) as? [String: Any] else { return nil }
        return obj["ExpirationDate"] as? Date
    }

    /// Whole days left (rounded down), never negative.
    public static func daysLeft(until expiry: Date, now: Date = Date()) -> Int { max(0, Int(expiry.timeIntervalSince(now) / 86_400)) }
}
