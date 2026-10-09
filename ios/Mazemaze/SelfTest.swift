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

            // ---- bars that slide away while reading
            await load("/scroll.html")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            report("reading: the bars are shown when a page opens", !tab.barsHidden)
            _ = await inPage("window.scrollTo(0, 150); 1")
            try? await Task.sleep(nanoseconds: 500_000_000)
            _ = await inPage("window.scrollTo(0, 800); 1")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            report("reading: scrolling down slides the address bar and toolbar away", tab.barsHidden)
            _ = await inPage("window.scrollBy(0, -90); 1")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            report("reading: scrolling up brings them back", !tab.barsHidden)
            _ = await inPage("window.scrollTo(0, 150); 1")
            try? await Task.sleep(nanoseconds: 500_000_000)
            _ = await inPage("window.scrollTo(0, 900); 1")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            tab.lastProblem = "テスト用の問題"
            report("reading: a problem brings the bars back", !tab.barsHidden)
            tab.lastProblem = nil
            app.settings.autoHideBars = false
            _ = await inPage("window.scrollTo(0, 100); 1")
            try? await Task.sleep(nanoseconds: 500_000_000)
            _ = await inPage("window.scrollTo(0, 1000); 1")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            report("reading: with the setting off the bars never hide", !tab.barsHidden)
            app.settings.autoHideBars = true

            // ---- dictionary: "辞書に保存" from the popover goes through the bridge
            func bridge(_ body: String) async -> Any? {
                await withCheckedContinuation { cont in
                    web.callAsyncJavaScript("return await window.webkit.messageHandlers.mazemaze.postMessage(\(body))", arguments: [:], in: nil, in: BrowserCoordinator.world) { r in
                        if case .success(let v) = r { cont.resume(returning: v) } else { cont.resume(returning: nil) }
                    }
                }
            }
            let dictBefore = app.dictionary.entries.count
            let saved = await bridge(#"{type:"save", en:"good weather", ja:"良い天気"}"#) as? [String: Any]
            report("dictionary: a save request stores the expression (with the page as its source)", (saved?["status"] as? String) == "saved" && app.dictionary.entries.count == dictBefore + 1 && app.dictionary.entries.first?.japanese == "良い天気" && !(app.dictionary.entries.first?.source.isEmpty ?? true), "\(saved ?? [:]) \(app.dictionary.entries.first.map { "\($0.source)" } ?? "-")")
            let dup = await bridge(#"{type:"save", en:"Good  weather", ja:"良い天気"}"#) as? [String: Any]
            report("dictionary: the same expression is reported as already saved", (dup?["status"] as? String) == "duplicate" && app.dictionary.entries.count == dictBefore + 1)
            let bad = await bridge(#"{type:"save", en:"x", ja:"y", url:"https://evil.example/"}"#)
            report("dictionary: a request with extra fields is refused", bad == nil && app.dictionary.entries.count == dictBefore + 1)
            let reloaded = DictionaryStorage(fileURL: app.dictionaryStorage.fileURL).load()
            report("dictionary: what was saved is on disk", reloaded.entries.count == dictBefore + 1 && reloaded.entries.first?.english == "good weather")
            if let id = app.dictionary.entries.first?.id { app.removeFromDictionary(ids: [id]) }
            report("dictionary: deleting removes it (and from disk)", app.dictionary.entries.count == dictBefore && DictionaryStorage(fileURL: app.dictionaryStorage.fileURL).load().entries.count == dictBefore)

            // ---- "貼り付けて翻訳": the app's own page, same pipeline, not a tab, not reachable from anywhere else
            let pasteLines = ["今日は晴れていて、散歩に出かけるのにちょうど良い天気です。", "", "短い", "<img src=x onerror=window.__xss=1>テストの文章がここにあります。これは日本語の文章です。", "もう一行、日本語のしっかりした長さの文章がここに入ります。それから続きます。"]
            let pasteOriginal = pasteLines.joined(separator: "\n")
            let tabsBeforePaste = app.tabs.count
            app.openPaste()                                  // the result page must be on screen (visible-first translation)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            app.startPaste(lines: pasteLines)
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let pt = app.pasteTab {
                var ok = 0
                for _ in 0..<150 { ok = pt.okCount; if ok > 0 { break }; try? await Task.sleep(nanoseconds: 400_000_000) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                report("paste: it is not one of the tabs (never listed, saved or put to sleep)", app.tabs.count == tabsBeforePaste && !app.tabs.contains { $0.id == pt.id })
                var ptStatus: [String: Any] = [:]
                if let w = pt.webView {
                    ptStatus = await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
                        w.callAsyncJavaScript("return window.__mazemaze ? window.__mazemaze.status() : { missing: true, nodes: document.querySelectorAll('#out > div').length }", arguments: [:], in: nil, in: BrowserCoordinator.world) { r in
                            if case .success(let v) = r, let d = v as? [String: Any] { cont.resume(returning: d) } else { cont.resume(returning: ["evalFailed": true]) }
                        }
                    }
                }
                report("paste: the page is the app's own address and the same translation pipeline works on it", PasteSurface.isPasteURL(pt.webView?.url) && ok > 0, "url=\(pt.webView?.url?.absoluteString ?? "nil") ok=\(ok) problem=\(pt.lastProblem ?? "-") site=\(pt.siteStatus) status=\(ptStatus)")
                let shown = await pt.coordinator?.pasteText() ?? ""
                report("paste: English is mixed in and the line structure is kept", shown != pasteOriginal && shown.split(separator: "\n", omittingEmptySubsequences: false).count == pasteLines.count && !shown.contains("\u{200B}"), shown)
                if let w = pt.webView {
                    let seen = await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
                        w.callAsyncJavaScript("return { api: typeof window.__mazemaze, handler: typeof (window.webkit && window.webkit.messageHandlers), xss: typeof window.__xss, imgs: document.querySelectorAll('#out img').length }", arguments: [:], in: nil, in: .page) { r in
                            if case .success(let v) = r { cont.resume(returning: v as? [String: Any]) } else { cont.resume(returning: nil) }
                        }
                    }
                    report("paste: the page itself cannot see the translator or the bridge, and pasted markup stays text", (seen?["api"] as? String) == "undefined" && (seen?["xss"] as? String) == "undefined" && (seen?["imgs"] as? Int) == 0, "\(seen ?? [:])")
                    w.load(URLRequest(url: URL(string: "https://example.com/")!))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    report("paste: the page cannot be taken anywhere else", PasteSurface.isPasteURL(w.url), "\(w.url?.absoluteString ?? "nil")")
                }
                if let w1 = first.webView {
                    w1.load(URLRequest(url: PasteSurface.url))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    report("paste: no ordinary tab can open the app's private address", !PasteSurface.touchesPasteHost(w1.url), "\(w1.url?.absoluteString ?? "nil")")
                }
                pt.restoreOriginal()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let restored = await pt.coordinator?.pasteText() ?? ""
                report("paste: \"原文に戻す\" restores exactly what was pasted", restored == pasteOriginal, restored)
            } else {
                report("paste: a result page is created", false)
            }
            app.closePaste()
            try? await Task.sleep(nanoseconds: 800_000_000)
            report("paste: closing it drops the result page and the screen", app.pasteTab == nil && !app.showPaste)
            app.activate(first.id)
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let w = first.webView { web = w }

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
