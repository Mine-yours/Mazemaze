#if DEBUG
import Foundation
import WebKit
import MazemazeCore

/// Debug-only measurement run (`-MazemazeBench 1 -MazemazeInitialURL <url> -MazemazeAPI … -MazemazeToken …`).
/// Prints how long it takes until the first translation appears and how fast the page fills in.
/// Only counts and milliseconds are printed, never page text.
@MainActor
enum Bench {
    static var isActive: Bool { SelfTest.value("-MazemazeBench") == "1" }
    static var hasStarted = false

    static func start(web: WKWebView, app: AppModel) {
        Task { @MainActor in await run(web: web, app: app) }
    }

    static func status(_ web: WKWebView) async -> [String: Any] {
        await withCheckedContinuation { cont in
            web.callAsyncJavaScript("return window.__mazemaze ? window.__mazemaze.status() : null", arguments: [:], in: nil, in: BrowserCoordinator.world) { r in
                if case .success(let v) = r, let d = v as? [String: Any] { cont.resume(returning: d) } else { cont.resume(returning: [:]) }
            }
        }
    }

    static func run(web: WKWebView, app: AppModel) async {
        let tab = app.active
        let navStart = Date()
        print("BENCH START")
        // Wait for the page to finish loading.
        for _ in 0..<600 { if !web.isLoading, web.url != nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        let loadedAt = Date()
        print("BENCH pageLoadMs=\(Int(loadedAt.timeIntervalSince(navStart) * 1000))")
        var firstReported = false
        var nextMark = 0
        let marks = [5, 10, 20, 30, 45, 60, 90]
        let limit = Double(SelfTest.value("-MazemazeBenchSeconds").flatMap(Int.init) ?? 90)
        while Date().timeIntervalSince(loadedAt) < limit {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let elapsed = Date().timeIntervalSince(loadedAt)
            let st = await status(web)
            if !firstReported, (st["replaced"] as? Int ?? 0) > 0 {
                firstReported = true
                print("BENCH firstTranslationAfterLoadMs=\(Int(elapsed * 1000))")
            }
            if nextMark < marks.count, elapsed >= Double(marks[nextMark]) {
                print("BENCH t=\(marks[nextMark])s replaced=\(st["replaced"] ?? 0) english=\(st["english"] ?? 0) requests=\(st["requests"] ?? 0) ok=\(tab.okCount) fail=\(tab.failCount)")
                nextMark += 1
            }
        }
        let st = await status(web)
        if let m = st["metrics"] as? [String: Any] {
            print("BENCH jsTimeline startedAt=\(m["startedAt"] ?? "nil") firstSendAt=\(m["firstSendAt"] ?? "nil") firstApplyAt=\(m["firstApplyAt"] ?? "nil") maxVisibleBlocks=\(m["maxVisible"] ?? 0)")
            if let reqs = m["reqs"] as? [[String: Any]] {
                let ms = reqs.compactMap { $0["ms"] as? Int }.sorted()
                let chars = reqs.compactMap { $0["chars"] as? Int }
                if !ms.isEmpty {
                    let p50 = ms[ms.count / 2], p90 = ms[min(ms.count - 1, Int(Double(ms.count) * 0.9))]
                    print("BENCH requests n=\(ms.count) msP50=\(p50) msP90=\(p90) msMax=\(ms.last!) charsMean=\(chars.reduce(0, +) / max(1, chars.count))")
                    print("BENCH requestMs=\(ms.map(String.init).joined(separator: ","))")
                }
            }
        }
        print("BENCH DONE")
        fflush(stdout)
        exit(0)
    }
}
#endif
