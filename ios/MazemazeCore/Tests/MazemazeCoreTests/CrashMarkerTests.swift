import XCTest
@testable import MazemazeCore

final class CrashMarkerTests: XCTestCase {
    private func marker() -> CrashMarker {
        CrashMarker(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)"))
    }

    func testAFinishedStepLeavesNothingBehind() {
        let m = marker()
        m.begin(); XCTAssertTrue(FileManager.default.fileExists(atPath: m.fileURL.path), "on disk before the risky step runs")
        m.end()
        XCTAssertFalse(m.consumeCrash())
    }

    func testAStepThatNeverFinishedIsReportedOnceAtTheNextLaunch() {
        let m = marker()
        m.begin()                                   // ... the app dies here ...
        XCTAssertTrue(CrashMarker(fileURL: m.fileURL).consumeCrash(), "the next launch sees it")
        XCTAssertFalse(CrashMarker(fileURL: m.fileURL).consumeCrash(), "and only once")
    }

    func testNothingToReportWithoutAMarker() { XCTAssertFalse(marker().consumeCrash()) }
}
