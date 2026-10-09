#if DEBUG
import Foundation
import WebKit
import MazemazeCore

/// Debug-only simulator self-test, driven by launch arguments (see ios/scripts/simulator_selftest.sh).
/// It is compiled out of Release builds, so the arguments do nothing there.
@MainActor
enum SelfTest {
    static var args: [String] { ProcessInfo.processInfo.arguments }
    static var isActive: Bool { value("-MazemazeSelfTest") == "1" }
    static func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func start(web: WKWebView, coordinator: BrowserCoordinator, model: AppModel) {
        Task { @MainActor in
            await Runner(web: web, coordinator: coordinator, model: model).run()
        }
    }

    @MainActor final class Runner {
        let web: WKWebView, coordinator: BrowserCoordinator, model: AppModel
        var passed = 0, failed = 0
        init(web: WKWebView, coordinator: BrowserCoordinator, model: AppModel) { self.web = web; self.coordinator = coordinator; self.model = model }

        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("SELFTEST \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " :: " + detail)")
        }

        func eval(_ js: String, world: WKContentWorld) async -> Any? {
            await withCheckedContinuation { cont in
                web.callAsyncJavaScript(js, arguments: [:], in: nil, in: world) { result in
                    if case .success(let v) = result { cont.resume(returning: v) } else { cont.resume(returning: nil) }
                }
            }
        }
        func inPage(_ js: String) async -> Any? { await eval(js, world: .page) }
        func inScript(_ js: String) async -> Any? { await eval(js, world: BrowserCoordinator.world) }

        func load(_ path: String) async {
            let base = SelfTest.value("-MazemazeStartURL") ?? ""
            guard let url = URL(string: base + path) else { return }
            web.load(URLRequest(url: url))
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !web.isLoading, web.url?.path == url.path { break }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        func waitFor(_ js: String, seconds: Double = 60) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let v = await inScript(js) as? Bool, v { return true }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return false
        }

        func statusJSON() async -> [String: Any] {
            (await inScript("return window.__mazemaze ? window.__mazemaze.status() : null") as? [String: Any]) ?? [:]
        }

        func run() async {
            print("SELFTEST START")
            await load("/static.html")
            let before = (await inPage("return document.body.innerHTML")) as? String ?? ""
            let translated = await waitFor("return !!window.__mazemaze && window.__mazemaze.status().replaced > 0")
            let st = await statusJSON()
            report("allowed page is translated by the native bridge", translated, "\(st)")
            report("English spans exist", ((st["english"] as? Int) ?? 0) > 0)
            report("server was reached (ok count)", model.okCount > 0, "ok=\(model.okCount) fail=\(model.failCount) problem=\(model.lastProblem ?? "-")")

            let leak = await inPage("return [typeof window.__mazemaze, typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mazemaze)].join(',')") as? String
            report("page world cannot see the script or the native handler", leak == "undefined,undefined", leak ?? "nil")
            let direct = await inPage("""
              try { const r = await fetch('\(SelfTest.value("-MazemazeAPI") ?? "http://127.0.0.1:8000")/api/status'); return 'reached:' + r.status; } catch (e) { return 'blocked'; }
            """) as? String
            report("page script cannot read the API (CORS/no token; supplementary, the typeof check above is the real isolation proof)", direct == "blocked" || direct == "reached:401" || direct == "reached:403", direct ?? "nil")

            let unchanged = await inPage("""
              const ids = ['link','pre','ta','btn','edit','hid','nt','p3'];
              return ids.map(i => { const e = document.getElementById(i); return e ? (e.value !== undefined && e.tagName==='TEXTAREA' ? e.value : e.textContent) : null }).join('|')
            """) as? String ?? ""
            report("links, code, inputs and English-only text are untouched", unchanged.contains("このリンクの文字は翻訳しません") && unchanged.contains("入力欄の中の日本語") && unchanged.contains("English only"), unchanged.prefix(80).description)

            // Tap on an English span shows the original (dispatch a real click event in the page).
            _ = await inScript("const e = document.querySelector('[data-mz-en]'); e.click(); return 1")
            let popover = await inScript("const p = document.querySelector('[data-mazemaze-ui]'); return p ? p.textContent : null") as? String
            report("tapping English shows the original Japanese", (popover ?? "").unicodeScalars.contains { $0.value >= 0x3040 }, popover ?? "nil")

            // Toggle off restores the page exactly; on again translates again.
            model.translationEnabled = false
            let restored = await waitFor("return window.__mazemaze.status().replaced === 0 && !window.__mazemaze.status().enabled", seconds: 10)
            let afterOff = (await inPage("return document.body.innerHTML")) as? String ?? ""
            report("toggle OFF restores the original DOM exactly", restored && afterOff == before)
            model.translationEnabled = true
            let again = await waitFor("return window.__mazemaze.status().replaced > 0")
            report("toggle ON translates again (cache makes it quick)", again)
            model.restoreOriginal()
            let manual = await waitFor("return window.__mazemaze.status().replaced === 0", seconds: 10)
            let afterRestore = (await inPage("return document.body.innerHTML")) as? String ?? ""
            report("restore-original button restores the DOM exactly", manual && afterRestore == before)
            model.resumeTranslation()

            // Denied path: same page content under /login must not be translated or sent.
            await load("/login")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let deniedStatus = await statusJSON()
            report("login path is never translated", ((deniedStatus["replaced"] as? Int) ?? 0) == 0 && model.okCount == 0 && model.failCount == 0 && !model.decision(for: web.url).isAllowed, "\(deniedStatus)")

            // Password page: allowed path but blocked by the script.
            await load("/login.html")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let pw = await statusJSON()
            report("password page is blocked", (pw["blocked"] as? String) == "password" && ((pw["replaced"] as? Int) ?? 0) == 0, "\(pw)")

            // Dynamic page: content added after load is translated.
            model.resumeTranslation()
            await load("/dynamic.html")
            _ = await waitFor("return window.__mazemaze.status().replaced > 0")
            _ = await inPage("addMany(3); return 1")
            let dyn = await waitFor("return document.querySelectorAll('#dyn0 [data-mz-en], #dyn1 [data-mz-en], #dyn2 [data-mz-en]').length > 0")
            report("content added later is translated", dyn)

            // Wrong token: the page keeps its original text and the user sees a clear message.
            let goodToken = model.settings.token
            try? model.settings.setToken("wrong-token")
            model.configChanged()
            await load("/static.html")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let wrong = await statusJSON()
            report("wrong token: no replacement, clear message, translation stops", ((wrong["replaced"] as? Int) ?? 0) == 0 && (model.lastProblem ?? "").contains("トークン") && (wrong["stopped"] as? String) == "unauthorized", "problem=\(model.lastProblem ?? "-") status=\(wrong)")
            try? model.settings.setToken(goodToken)
            model.configChanged()

            print("SELFTEST DONE passed=\(passed) failed=\(failed)")
            fflush(stdout)
            exit(failed == 0 ? 0 : 1)
        }
    }
}
#endif
