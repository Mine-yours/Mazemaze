import SwiftUI
import UniformTypeIdentifiers
import MazemazeCore

/// The file the backup is written to (the person picks where: Files, iCloud Drive, ...). Nothing is sent by the app.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// The signature of an app installed with a free Apple ID runs out after 7 days. The profile Xcode put inside the app says when.
enum AppSignature {
    static func expiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: url) else { return nil }
        return ProvisioningProfile.expirationDate(from: data)
    }
}

extension AppModel {
    var signatureExpiry: Date? { AppSignature.expiry() }

    /// Days until the signature runs out, when it can be read.
    var signatureDaysLeft: Int? { signatureExpiry.map { ProvisioningProfile.daysLeft(until: $0) } }

    func makeBackupData() -> Data? {
        try? Backup.encode(Backup.make(dictionary: dictionary, favorites: bookmarks.favorites, allowedHosts: allowedHosts))
    }

    var backupFileName: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd"
        return "mazemaze-backup-\(f.string(from: Date()))"
    }
}
