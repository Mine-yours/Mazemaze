import SwiftUI
import WebKit
import MazemazeCore

/// WKWebView wrapper. The translation script and its message handler live in a private
/// WKContentWorld, so scripts of the visited site can neither see nor call them. Page text only
/// ever goes to the on-device engines, from the Swift side.
/// Shows the web view that belongs to a tab. The web view lives in the tab (not in this view), so
/// switching tabs never reloads a page.
struct BrowserView: UIViewControllerRepresentable {
    let tab: TabModel
    /// The part of the screen covered by the address bar / toolbar. The page is laid out around it (as a safe area),
    /// so fixed headers and 100vh behave, and it grows to the whole screen when the bars slide away.
    var covered: UIEdgeInsets = .zero

    func makeUIViewController(context: Context) -> WebHostController { WebHostController(webView: tab.ensureWebView()) }
    func updateUIViewController(_ vc: WebHostController, context: Context) { vc.covered = covered }
}

/// Holds the tab's web view edge to edge and tells it how much of the screen the bars cover.
final class WebHostController: UIViewController {
    let webView: WKWebView
    var covered: UIEdgeInsets = .zero { didSet { if covered != oldValue { additionalSafeAreaInsets = covered } } }

    init(webView: WKWebView) { self.webView = webView; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = UIView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        // The page starts below the status bar. Pages that ask for `viewport-fit=cover` (X does) are laid out under the
        // notch / status bar and expect the browser to keep its own chrome there: a header fixed at the top of such a
        // page would otherwise sit behind the status bar.
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        additionalSafeAreaInsets = covered
    }
}

@MainActor
final class BrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: "MazemazeWorld")

    unowned let tab: TabModel
    unowned let app: AppModel
    private(set) weak var webView: WKWebView?
    private var observers: [NSKeyValueObservation] = []
    private var lastURL: URL?
    private var lastMainFrameRequest: URL?     // the latest main-frame request seen (redirect hops update it)
    private var lastUserRequestedURL: URL?     // what the user typed or tapped; used for "open in Safari"
    private var lastIntentionalCancel = Date.distantPast
    private var hintTask: Task<Void, Never>?
    private var pasteNavigationUsed = false     // the paste page may load once (the app's own template) and never navigate again

    init(tab: TabModel, app: AppModel) { self.tab = tab; self.app = app }

    func makeWebView(initialURL: URL?) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // The paste page uses a throw-away data store: nothing about it is kept on disk.
        config.websiteDataStore = tab.kind == .paste ? .nonPersistent() : .default()
        let ucc = config.userContentController
        ucc.addScriptMessageHandler(self, contentWorld: Self.world, name: "mazemaze")
        if let url = Bundle.main.url(forResource: "translator", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        }
        // X only (owner's decision of 2026-10-09, see BrowserIdentity): the page script itself checks the host.
        if app.settings.safariIdentityForX {
            ucc.addUserScript(WKUserScript(source: BrowserIdentity.xPageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = tab.kind == .web
        #if DEBUG
        web.isInspectable = true
        #endif
        webView = web
        observe(web)
        bindModel(web)
        if tab.kind == .paste { loadPasteTemplate(web); return web }
        #if DEBUG
        // The self-test drives the first web view only; later tabs are ordinary.
        if SelfTest.isActive, !SelfTest.hasStarted { SelfTest.hasStarted = true; SelfTest.start(web: web, coordinator: self, app: app); return web }
        #endif
        if let initialURL {
            lastUserRequestedURL = initialURL
            web.load(URLRequest(url: initialURL))
        }
        return web
    }

    /// Release everything the web view holds on to (the script handler keeps the coordinator alive).
    func teardown() {
        hintTask?.cancel()
        observers = []
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        let ucc = web.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "mazemaze", contentWorld: Self.world)
        ucc.removeAllUserScripts()
    }

    private func observe(_ web: WKWebView) {
        observers = [
            web.observe(\.url, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.urlChanged(w) }
            },
            web.observe(\.title, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.tab.pageTitle = w.title ?? "" } },
            web.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.tab.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.tab.canGoForward = w.canGoForward } },
            web.observe(\.isLoading, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.tab.isLoading = w.isLoading } },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.tab.progress = w.estimatedProgress } },
            web.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                MainActor.assumeIsolated {
                    // Only a finger (dragging / the fling after it) hides the bars: not an anchor jump, a script or a relayout.
                    var driven = sv.isDragging || sv.isDecelerating
                    #if DEBUG
                    if SelfTest.isActive || SelfTest.value("-MazemazeScrollDemo") == "1" { driven = true }      // tests scroll with scripts
                    #endif
                    self?.tab.scrolled(offset: Double(sv.contentOffset.y), minOffset: Double(-sv.adjustedContentInset.top), userDriven: driven)
                }
            },
        ]
    }

    private func bindModel(_ web: WKWebView) {
        tab.loadURL = { [weak self, weak web] url in
            // Remember it for "open in Safari" only if it is an ordinary web address.
            if ExternalNavigation.classify(url) == .allowInApp { self?.lastUserRequestedURL = url }
            web?.load(URLRequest(url: url))
        }
        tab.goBack = { [weak web] in web?.goBack() }
        tab.goForward = { [weak web] in web?.goForward() }
        tab.reload = { [weak web] in web?.reload() }
        tab.stopLoading = { [weak web] in web?.stopLoading() }
        tab.pushConfigToPage = { [weak self] in self?.pushConfig() }
        tab.restoreOriginalInPage = { [weak self] in self?.runInWorld("if (window.__mazemaze) { window.__mazemaze.restoreAll(); }") }
        tab.pauseInPage = { [weak self] in self?.runInWorld("if (window.__mazemaze) { window.__mazemaze.pause(); }") }
        tab.resumeInPage = { [weak self] in self?.runInWorld("if (window.__mazemaze) { window.__mazemaze.resume(); }") }
    }

    // MARK: URL changes (including single-page-app route changes that never "navigate")
    /// The URL of the document that is really on screen. `webView.url` also reports the target of a
    /// load that is still in progress (and may be cancelled), the back-forward list does not.
    private func committedURL(_ web: WKWebView) -> URL? {
        if tab.kind == .paste { return PasteSurface.isPasteURL(web.url) ? web.url : nil }
        return web.backForwardList.currentItem?.url ?? web.url
    }

    private func urlChanged(_ web: WKWebView) {
        guard tab.kind == .web else { return }          // the paste page has no address bar, history or saved state
        if let url = web.url { tab.addressText = url.absoluteString }
        let committed = committedURL(web)
        tab.currentURL = committed
        // Fragment-only changes (#section) are the same page, and a load that was cancelled leaves the
        // committed page unchanged. Anything else is a new page (including a single-page-app route
        // change): older requests become stale and the page script starts over.
        guard Self.withoutFragment(committed) != Self.withoutFragment(lastURL) else { return }
        lastURL = committed
        app.tabsChanged()
        Task { @MainActor in
            await tab.pageWillChange()        // bump the generation first ...
            pushConfig()                      // ... then read it back, so the page gets the new one
        }
    }

    static func withoutFragment(_ url: URL?) -> String? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        return c.string
    }

    func runInWorld(_ script: String, arguments: [String: Any] = [:]) {
        webView?.callAsyncJavaScript(script, arguments: arguments, in: nil, in: Self.world) { _ in }
    }

    /// Tell the page script what to do for the current URL and generation. The decision (allowed
    /// site, path, enabled) is made here from the WebView's real URL, never by the page.
    func pushConfig() {
        guard let web = webView else { return }
        Task { @MainActor in
            let gen = await app.service.generation(of: tab.id)
            let cfg = tab.pageConfig(for: committedURL(web), gen: gen)
            runInWorld("if (window.__mazemaze) { window.__mazemaze.configure(cfg); }", arguments: ["cfg": cfg])
        }
    }

    // MARK: messages from the page script
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.name == "mazemaze", message.frameInfo.isMainFrame, let web = message.webView,
              let pageURL = committedURL(web), message.frameInfo.securityOrigin.host == pageURL.host,
              message.frameInfo.securityOrigin.protocol == pageURL.scheme else {
            return (nil, "not allowed")
        }
        switch BridgeMessage.parse(message.body) {
        case .failure:
            return (nil, "bad message")
        case .success(.ready):
            let gen = await app.service.generation(of: tab.id)
            return (tab.pageConfig(for: pageURL, gen: gen), nil)
        case .success(.save(let en, let ja)):
            guard app.decision(for: pageURL).isAllowed else { return (["ok": false, "error": "not_allowed", "message": "このページでは保存できません"], nil) }
            return (app.saveToDictionary(english: en, japanese: ja, pageURL: pageURL), nil)
        case .success(.lookup(let request)):
            guard app.decision(for: pageURL).isAllowed else { return (["ok": false, "error": "not_allowed", "message": "このページでは調べられません"], nil) }
            app.openLookup(request, pageURL: pageURL)
            return (["ok": true], nil)
        case .success(.translate(let gen, let text)):
            // Re-check on every request: a single-page app may have moved to a denied page.
            guard app.decision(for: pageURL).isAllowed, app.translationEnabled, !tab.suspendedForPage else {
                return (["ok": false, "error": "not_allowed", "message": "このページは翻訳しません"], nil)
            }
            return (await tab.translate(gen: gen, text: text), nil)
        }
    }

    // MARK: navigation
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if tab.kind == .paste {
            // Only the app's own template load is allowed (the first main-frame navigation); no link, script or
            // redirect can take this page anywhere else.
            if isMainFrame, !pasteNavigationUsed { pasteNavigationUsed = true; return .allow }
            return .cancel
        }
        guard let url = navigationAction.request.url else { return .cancel }
        switch ExternalNavigation.classify(url) {
        case .blocked:
            // Embedded widgets (iframes) may use about:/blob:/data:; only the top level is restricted.
            if !isMainFrame, ["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") { return .allow }
            lastIntentionalCancel = Date()
            return .cancel
        case .safariRedirect(let httpsURL):
            // The site refuses in-app browsers and sends us to Safari. We do not work around that
            // (no workarounds beyond the X-only identity, see BrowserIdentity); show an explanation instead of a blank page.
            lastIntentionalCancel = Date()
            guard isMainFrame else { return .cancel }
            var asked = lastUserRequestedURL ?? lastMainFrameRequest ?? httpsURL
            if !["http", "https"].contains(asked.scheme?.lowercased() ?? "") { asked = httpsURL }   // only a web address may go to Safari
            tab.blockedNavigation = BlockedNavigation(kind: .safariRedirect, openURL: asked, host: asked.host ?? httpsURL.host ?? "")
            tab.addressText = asked.absoluteString          // show what was asked for, not the redirect
            tab.siteStatus = "このサイトはアプリ内ブラウザに対応していません（Safari で開けます）"
            return .cancel
        case .external(let ext):
            lastIntentionalCancel = Date()
            // Only after a real tap; a page that redirects to another app by itself is just ignored.
            if isMainFrame, navigationAction.navigationType == .linkActivated {
                tab.blockedNavigation = BlockedNavigation(kind: .otherApp, openURL: ext, host: ext.scheme ?? "")
            }
            return .cancel
        case .allowInApp:
            // Only a navigation of THIS web view's main frame (not target=_blank, which opens a new tab) may change its identity.
            if navigationAction.targetFrame?.isMainFrame == true { await applyIdentity(for: url, on: webView) }
            if navigationAction.targetFrame == nil {
                // target=_blank: open it in a new tab, but only for a real tap (no script-opened popups).
                if navigationAction.navigationType == .linkActivated { app.newTab(url: url) }
                return .cancel
            }
            if isMainFrame, url.scheme != "about" {
                lastMainFrameRequest = url
                if navigationAction.navigationType == .linkActivated { lastUserRequestedURL = url }
            }
            return .allow
        }
    }

    #if DEBUG
    /// Simulator only: scroll the page down and up the way a finger would, and report the viewport.
    func debugScrollDemo(_ web: WKWebView) async {
        func report(_ tag: String) async {
            let js = "return JSON.stringify({ h: window.innerHeight, w: window.innerWidth, y: Math.round(window.scrollY), fixedTop: (document.getElementById('fx') ? Math.round(document.getElementById('fx').getBoundingClientRect().top) : null) })"
            let r = try? await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            print("SCROLLDEMO \(tag) hidden=\(tab.barsHidden) off=\(Int(web.scrollView.contentOffset.y)) adj=\(web.scrollView.adjustedContentInset) \(r as? String ?? "nil")")
            fflush(stdout)
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await report("start")
        _ = try? await web.callAsyncJavaScript("window.scrollTo(0, 150)", arguments: [:], in: nil, contentWorld: .page)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await report("scrolled-150")
        _ = try? await web.callAsyncJavaScript("window.scrollTo(0, 700)", arguments: [:], in: nil, contentWorld: .page)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await report("scrolled-700 (bars should be away)")
        _ = try? await web.callAsyncJavaScript("window.scrollBy(0, -60)", arguments: [:], in: nil, contentWorld: .page)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await report("up-60 (bars should be back)")
    }
    #endif

    // MARK: browser identity (X only, owner's decision of 2026-10-09; see BrowserIdentity)
    private static var defaultUserAgent: String?

    /// X sends a bare WKWebView ("…Mobile/15E148", no Safari tokens) to Safari. For X hosts only, add Safari's
    /// standard tokens; every other site keeps the web view's own user agent.
    private func applyIdentity(for url: URL, on web: WKWebView) async {
        guard BrowserIdentity.wantsSafariIdentity(host: url.host), app.settings.safariIdentityForX else {
            if web.customUserAgent != nil { web.customUserAgent = nil }
            return
        }
        if Self.defaultUserAgent == nil, let ua = try? await web.evaluateJavaScript("navigator.userAgent", in: nil, contentWorld: Self.world) as? String { Self.defaultUserAgent = ua }
        guard let base = Self.defaultUserAgent else { return }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        web.customUserAgent = BrowserIdentity.safariStyle(from: base, osMajor: os.majorVersion, osMinor: os.minorVersion)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open(): WebKit only gets here for a user gesture. A new tab, not a pop-up window.
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            app.newTab(url: url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Not final yet: the load may still be cancelled (Safari redirect) or fail, in which case the
        // page underneath is untouched. Generation, counters and the "show original" choice are
        // changed only when a new document commits (see didCommit).
        tab.dismissBlockedNavigation()
        hintTask?.cancel()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastURL = committedURL(webView)     // this document is now the committed one (keeps the KVO path from bumping twice)
        lastUserRequestedURL = nil
        // A real document load (including a reload of the same URL): new generation, fresh counters,
        // and the "this page shows the original" choice is forgotten. The new document asks for its
        // configuration itself once it is ready.
        tab.resetCounters()
        tab.resetBars()
        Task { @MainActor in
            await tab.pageWillChange()
            pushConfig()      // a no-op while the new document has no script yet; covers pages restored from the cache
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if tab.kind == .paste { fillPaste(); return }
        #if DEBUG
        if SelfTest.value("-MazemazeScrollDemo") == "1" { Task { @MainActor in await self.debugScrollDemo(webView) } }
        #endif
        app.recordVisit(of: tab)
        scheduleNothingToTranslateHint()
    }

    // MARK: the paste page ("貼り付けて翻訳")
    private static let pasteFillScript = (Bundle.main.url(forResource: "paste_fill", withExtension: "js")).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let pasteTextScript = (Bundle.main.url(forResource: "paste_text", withExtension: "js")).flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The app's own page: fixed template, no script of its own, address that can never be reached on the network.
    private func loadPasteTemplate(_ web: WKWebView) {
        guard let url = Bundle.main.url(forResource: "paste", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            tab.lastProblem = "貼り付け画面を読み込めません（アプリの再インストールが必要かもしれません）"
            return
        }
        pasteNavigationUsed = false
        web.loadHTMLString(html, baseURL: PasteSurface.url)
    }

    /// Put the pasted lines on the page (as arguments, never spliced into code; textContent only).
    private func fillPaste() {
        guard let web = webView, let script = Self.pasteFillScript else { return }
        web.callAsyncJavaScript(script, arguments: ["lines": tab.pasteLines], in: nil, in: Self.world) { _ in }
    }

    /// What the paste page shows now, as plain text (for "コピー").
    func pasteText() async -> String? {
        guard let web = webView, let script = Self.pasteTextScript else { return nil }
        return await withCheckedContinuation { cont in
            web.callAsyncJavaScript(script, arguments: [:], in: nil, in: Self.world) { result in
                if case .success(let v) = result, let s = v as? String { cont.resume(returning: s) } else { cont.resume(returning: nil) }
            }
        }
    }

    /// If, a few seconds after the page loaded, nothing was found to translate (a list of links,
    /// a menu page), say so instead of leaving the user wondering whether the app works.
    private func scheduleNothingToTranslateHint() {
        hintTask?.cancel()
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard let self, !Task.isCancelled, let web = self.webView else { return }
            guard self.app.decision(for: web.url).isAllowed, self.app.translationEnabled, !self.tab.suspendedForPage,
                  self.app.translationAvailable, self.tab.blockedNavigation == nil,
                  self.tab.inflight == 0, self.tab.okCount == 0, self.tab.failCount == 0, self.tab.lastProblem == nil else { return }
            let st = await self.statusFromPage()
            let enabled = (st["enabled"] as? Bool) ?? ((st["enabled"] as? Int) == 1)
            if enabled, st["stopped"] == nil || st["stopped"] is NSNull, (st["replaced"] as? Int ?? 0) == 0, (st["requests"] as? Int ?? 0) == 0, st["blocked"] == nil || st["blocked"] is NSNull {
                self.tab.siteStatus = "翻訳: このページには翻訳できる本文が見つかりません（記事ページを開くと翻訳されます）"
            }
        }
    }

    func statusFromPage() async -> [String: Any] {
        guard let web = webView else { return [:] }
        return await withCheckedContinuation { cont in
            web.callAsyncJavaScript("return window.__mazemaze ? window.__mazemaze.status() : null", arguments: [:], in: nil, in: Self.world) { result in
                if case .success(let v) = result, let d = v as? [String: Any] { cont.resume(returning: d) } else { cont.resume(returning: [:]) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    private func reportLoadError(_ error: Error) {
        let e = error as NSError
        guard e.code != NSURLErrorCancelled else { return }
        // "Frame load interrupted" is what WebKit reports after we refused a navigation on purpose.
        if e.domain == "WebKitErrorDomain", e.code == 102, Date().timeIntervalSince(lastIntentionalCancel) < 3 { return }
        tab.lastProblem = "ページを読み込めません（\(e.localizedDescription)）"
        tab.problemAction = .reload
    }

    private var lastCrashReload = Date.distantPast
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if tab.kind == .paste {      // the text is in memory: start the page again instead of reloading a page that is gone
            if Date().timeIntervalSince(lastCrashReload) > 15 { lastCrashReload = Date(); loadPasteTemplate(webView) }
            else { tab.lastProblem = "貼り付け画面が異常終了しました。一度閉じて、もう一度開いてください" }
            return
        }
        // Reload once; a page that keeps crashing must not put the app in a reload loop.
        guard Date().timeIntervalSince(lastCrashReload) > 15 else {
            tab.lastProblem = "このページは表示中に異常終了しました"
            return
        }
        lastCrashReload = Date()
        webView.reload()
    }
}
