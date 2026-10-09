import Foundation

/// A marker file around something that might crash the app (UIKit's dictionary view was one): written before, removed
/// after. If it is still there at the next launch, the app died in between, and the risky feature switches itself off.
public struct CrashMarker: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultMarker(named name: String) -> CrashMarker {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return CrashMarker(fileURL: dir.appendingPathComponent(name))
    }

    /// The risky step is about to start. The file is on disk before this returns.
    public func begin() { FileManager.default.createFile(atPath: fileURL.path, contents: Data()) }

    /// The risky step finished without the app dying.
    public func end() { try? FileManager.default.removeItem(at: fileURL) }

    /// At launch: true if the previous run died during the step (the marker is removed so this reports it once).
    @discardableResult
    public func consumeCrash() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        try? FileManager.default.removeItem(at: fileURL)
        return true
    }
}
