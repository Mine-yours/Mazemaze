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
    static var hasStarted = false
    static func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func start(web: WKWebView, coordinator: BrowserCoordinator, app: AppModel) {
        Task { @MainActor in
            await Runner(web: web, coordinator: coordinator, app: app).run()
        }
    }

    @MainActor final class Runner {
        var web: WKWebView
        let coordinator: BrowserCoordinator, app: AppModel
        var tab: TabModel { coordinator.tab }
        var passed = 0, failed = 0
        init(web: WKWebView, coordinator: BrowserCoordinator, app: AppModel) { self.web = web; self.coordinator = coordinator; self.app = app }

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

        func waitHint() async -> Bool {
            for _ in 0..<60 {
                if tab.siteStatus.contains("翻訳できる本文が見つかりません") { return true }
                try? await Task.sleep(nanoseconds: 500_000_000)
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
            report("server was reached (ok count)", tab.okCount > 0, "ok=\(tab.okCount) fail=\(tab.failCount) problem=\(tab.lastProblem ?? "-")")

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
            app.translationEnabled = false
            let restored = await waitFor("return window.__mazemaze.status().replaced === 0 && !window.__mazemaze.status().enabled", seconds: 10)
            let afterOff = (await inPage("return document.body.innerHTML")) as? String ?? ""
            report("toggle OFF restores the original DOM exactly", restored && afterOff == before)
            app.translationEnabled = true
            let again = await waitFor("return window.__mazemaze.status().replaced > 0")
            report("toggle ON translates again (cache makes it quick)", again)
            tab.restoreOriginal()
            let manual = await waitFor("return window.__mazemaze.status().replaced === 0", seconds: 10)
            let afterRestore = (await inPage("return document.body.innerHTML")) as? String ?? ""
            report("restore-original button restores the DOM exactly", manual && afterRestore == before)
            tab.resumeTranslation()

            // Denied path: same page content under /login must not be translated or sent.
            await load("/login")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let deniedStatus = await statusJSON()
            report("login path is never translated", ((deniedStatus["replaced"] as? Int) ?? 0) == 0 && tab.okCount == 0 && tab.failCount == 0 && !app.decision(for: web.url).isAllowed, "\(deniedStatus)")

            // Password page: allowed path but blocked by the script.
            await load("/login.html")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let pw = await statusJSON()
            report("password page is blocked", (pw["blocked"] as? String) == "password" && ((pw["replaced"] as? Int) ?? 0) == 0, "\(pw)")

            // Dynamic page: content added after load is translated.
            tab.resumeTranslation()
            await load("/dynamic.html")
            _ = await waitFor("return window.__mazemaze.status().replaced > 0")
            _ = await inPage("addMany(3); return 1")
            let dyn = await waitFor("return document.querySelectorAll('#dyn0 [data-mz-en], #dyn1 [data-mz-en], #dyn2 [data-mz-en]').length > 0")
            report("content added later is translated", dyn)

            // A site that sends in-app browsers to Safari: no blank page, an explanation instead, and the
            // page underneath keeps working (translation state untouched, restored after the card closes).
            tab.resumeTranslation()
            await load("/dynamic.html")
            _ = await waitFor("return window.__mazemaze.status().replaced > 0")
            try? await Task.sleep(nanoseconds: 2_000_000_000)      // let late KVO / commit bookkeeping settle
            let beforeCard = await statusJSON()
            let genBefore = await app.service.generation(of: tab.id)
            let pageURL = web.url
            web.evaluateJavaScript("location.href = '/to-safari'", completionHandler: nil)   // like tapping a link that redirects
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let blocked = tab.blockedNavigation
            report("x-safari redirect shows a Safari prompt instead of a blank page", blocked?.kind == .safariRedirect, "\(String(describing: blocked))")
            let during = await statusJSON()
            let genDuring = await app.service.generation(of: tab.id)
            report("the page underneath keeps its translation state while the card is up", (during["replaced"] as? Int ?? 0) == (beforeCard["replaced"] as? Int ?? -1) && genDuring == genBefore && web.url == pageURL, "before=\(beforeCard["replaced"] ?? "-") during=\(during["replaced"] ?? "-") gen \(genBefore)->\(genDuring)")
            tab.dismissBlockedNavigation()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            report("closing the card restores address and status", tab.addressText == web.url?.absoluteString && !tab.siteStatus.contains("対応していません"), "\(tab.addressText) | \(tab.siteStatus)")
            let after = await statusJSON()
            report("translation still works after the card closes", (after["gen"] as? Int) == (await app.service.generation(of: tab.id)), "\(after)")

            // Single-page-app route change (pushState) and a reload of the same URL both start a new generation.
            let gen0 = await app.service.generation(of: tab.id)
            _ = await inPage("history.pushState({}, '', '/dynamic.html?page=2'); return 1")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let gen1 = await app.service.generation(of: tab.id)
            let pageGen = (await statusJSON())["gen"] as? Int
            report("pushState route change starts a new generation and the page follows", gen1 > gen0 && pageGen == gen1, "\(gen0)->\(gen1) page=\(pageGen.map(String.init) ?? "nil")")
            web.reload()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let gen2 = await app.service.generation(of: tab.id)
            let pageGen2 = (await statusJSON())["gen"] as? Int
            report("reloading the same URL starts a new generation and the page follows", gen2 > gen1 && pageGen2 == gen2, "\(gen1)->\(gen2) page=\(pageGen2.map(String.init) ?? "nil")")
            tab.dismissBlockedNavigation()

            // Hint when a page has nothing translatable (links only).
            await load("/links.html")
            let hinted = await waitHint()
            report("a page with nothing translatable says so", hinted, tab.siteStatus)

            // ---- Tabs: switching never reloads, each tab has its own generation, sleeping tabs wake up, limits hold.
            let first = tab
            let firstView = first.webView
            await load("/static.html")
            _ = await waitFor("return !!window.__mazemaze && window.__mazemaze.status().replaced > 0")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let firstReplaced = (await statusJSON())["replaced"] as? Int ?? -1
            let genFirst = await app.service.generation(of: first.id)
            let base = SelfTest.value("-MazemazeStartURL") ?? ""
            let second = app.newTab(url: URL(string: base + "/static.html"))
            try? await Task.sleep(nanoseconds: 300_000_000)
            report("a new tab opens and becomes the active one", second != nil && app.activeID == second?.id && app.tabs.count == 2)
            func statusOf(_ t: TabModel?) async -> [String: Any] {
                guard let w = t?.webView else { return [:] }
                return await withCheckedContinuation { cont in
                    w.callAsyncJavaScript("return window.__mazemaze ? window.__mazemaze.status() : null", arguments: [:], in: nil, in: BrowserCoordinator.world) { r in
                        if case .success(let v) = r, let d = v as? [String: Any] { cont.resume(returning: d) } else { cont.resume(returning: [:]) }
                    }
                }
            }
            var secondReplaced = 0
            for _ in 0..<80 { secondReplaced = (await statusOf(second))["replaced"] as? Int ?? 0; if secondReplaced > 0 { break }; try? await Task.sleep(nanoseconds: 300_000_000) }
            report("the second tab translates on its own", secondReplaced > 0, "replaced=\(secondReplaced)")
            report("the first tab's generation is untouched by the second tab's navigation", await app.service.generation(of: first.id) == genFirst)
            app.activate(first.id)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let firstAfter = await statusOf(first)
            report("switching back keeps the same web view and the translation (no reload)",
                   first.webView === firstView && (firstAfter["replaced"] as? Int ?? -2) >= firstReplaced && (firstAfter["paused"] as? Bool) != true,
                   "replaced \(firstReplaced) -> \(firstAfter["replaced"] ?? "nil")")
            let pausedSecond = await statusOf(second)
            report("the tab that is no longer shown is paused", (pausedSecond["paused"] as? Bool) == true, "\(pausedSecond["paused"] ?? "nil")")
            for _ in 0..<4 { _ = app.newTab(url: URL(string: base + "/links.html")) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let live = app.tabs.filter { $0.webView != nil }.count
            report("at most \(AppModel.maxLiveTabs) tabs keep a web view; the others sleep", app.tabs.count == 6 && live <= AppModel.maxLiveTabs, "tabs=\(app.tabs.count) live=\(live)")
            let sleeper = app.tabs.first { $0.isSleeping }
            report("a sleeping tab remembers where it was", sleeper?.restoreURL != nil, "\(sleeper?.restoreURL?.absoluteString ?? "nil")")
            if let sleeper { app.activate(sleeper.id) }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            report("selecting a sleeping tab wakes it and loads its page", sleeper?.webView != nil && sleeper?.isSleeping == false && sleeper?.webView?.url != nil, "\(sleeper?.webView?.url?.absoluteString ?? "nil")")
            while app.tabs.count < AppModel.maxTabs { _ = app.newTab() }
            let overflow = app.newTab()
            report("the tab limit holds and says so", overflow == nil && app.tabNotice != nil && app.tabs.count == AppModel.maxTabs)
            app.tabNotice = nil
            if let victim = app.tabs.last {
                let vid = victim.id
                app.closeTab(vid)
                try? await Task.sleep(nanoseconds: 400_000_000)           // removeScope runs asynchronously
                let gone = !app.tabs.contains { $0.id == vid }
                let genGone = await app.service.generation(of: vid)
                report("closing a tab removes it and stales anything it still had in flight", gone && genGone > 0 && app.tabs.count == AppModel.maxTabs - 1)
            }
            app.activate(first.id)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let w = first.webView { web = w }       // the first tab may have slept and woken with a new web view

            // Wrong token: the page keeps its original text and the user sees a clear message.
            let goodToken = app.settings.token
            try? app.settings.setToken("wrong-token")
            app.configChanged()
            await load("/static.html")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let wrong = await statusJSON()
            report("wrong token: no replacement, clear message, translation stops", ((wrong["replaced"] as? Int) ?? 0) == 0 && (tab.lastProblem ?? "").contains("トークン") && (wrong["stopped"] as? String) == "unauthorized", "problem=\(tab.lastProblem ?? "-") status=\(wrong)")
            try? app.settings.setToken(goodToken)
            app.configChanged()

            // ---- Pairing over https with a pinned self-signed certificate
            if let good = SelfTest.value("-MazemazePairGood"), let wrong = SelfTest.value("-MazemazePairWrongPin") {
                let before = app.settings.serverURLString
                app.receivePairing(good)
                report("a pairing text is parsed but not applied until the person confirms", app.pendingPairing != nil && app.settings.serverURLString == before && app.settings.pinnedFingerprint == nil)
                app.confirmPairing()
                var state: ConnectionReport.State?
                for _ in 0..<100 { if let c = app.connection { state = c.state; break }; try? await Task.sleep(nanoseconds: 300_000_000) }
                report("paired: https with the pinned certificate works, and the unreachable .local name fell back to the IP address",
                       state == .ok && app.settings.pinnedFingerprint != nil && app.settings.serverConfig()?.baseURL.scheme == "https" && app.settings.serverConfig()?.fallbackURL != nil,
                       "state=\(String(describing: state)) \(app.connection?.message ?? "-")")
                await load("/static.html")
                let viaTLS = await waitFor("return !!window.__mazemaze && window.__mazemaze.status().replaced > 0", seconds: 40)
                report("translation works through the pinned TLS connection", viaTLS, "\(await statusJSON())")
                app.connection = nil
                app.receivePairing(wrong)
                app.confirmPairing()
                var wrongState: ConnectionReport?
                for _ in 0..<100 { if let c = app.connection { wrongState = c; break }; try? await Task.sleep(nanoseconds: 300_000_000) }
                report("a server with a different certificate is refused with a clear message", wrongState?.state == .failed && (wrongState?.message ?? "").contains("証明書"), wrongState?.message ?? "nil")
                _ = await app.service.translate(scope: tab.id, gen: await app.service.generation(of: tab.id), text: "証明書が違うサーバーへ送ろうとするテキスト")
                let again = await app.checkConnection()
                report("it keeps refusing (no silent downgrade to http)", again.state == .failed && app.settings.serverConfig()?.baseURL.scheme == "https", again.message)
            }

            print("SELFTEST DONE passed=\(passed) failed=\(failed)")
            fflush(stdout)
            exit(failed == 0 ? 0 : 1)
        }
    }
}
#endif
