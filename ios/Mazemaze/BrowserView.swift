import SwiftUI
import WebKit
import MazemazeCore

/// WKWebView wrapper. The translation script and its message handler live in a private
/// WKContentWorld, so scripts of the visited site can neither see nor call them. All network
/// access (and the token) stays on the Swift side.
struct BrowserView: UIViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> BrowserCoordinator { BrowserCoordinator(model: model) }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class BrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: "MazemazeWorld")
    static let homepage = URL(string: "https://news.yahoo.co.jp/")!

    let model: AppModel
    private(set) weak var webView: WKWebView?
    private var observers: [NSKeyValueObservation] = []
    private var lastURL: URL?

    init(model: AppModel) { self.model = model }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()
        let ucc = config.userContentController
        ucc.addScriptMessageHandler(self, contentWorld: Self.world, name: "mazemaze")
        if let url = Bundle.main.url(forResource: "translator", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        #if DEBUG
        web.isInspectable = true
        #endif
        webView = web
        observe(web)
        bindModel(web)
        #if DEBUG
        if SelfTest.isActive { SelfTest.start(web: web, coordinator: self, model: model); return web }
        #endif
        #if DEBUG
        if let u = SelfTest.value("-MazemazeInitialURL").flatMap(URL.init(string:)) { web.load(URLRequest(url: u)); return web }
        #endif
        web.load(URLRequest(url: Self.homepage))
        return web
    }

    private func observe(_ web: WKWebView) {
        observers = [
            web.observe(\.url, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.urlChanged(w) }
            },
            web.observe(\.title, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.model.pageTitle = w.title ?? "" } },
            web.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.model.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.model.canGoForward = w.canGoForward } },
            web.observe(\.isLoading, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.model.isLoading = w.isLoading } },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.model.progress = w.estimatedProgress } },
        ]
    }

    private func bindModel(_ web: WKWebView) {
        model.loadURL = { [weak web] url in web?.load(URLRequest(url: url)) }
        model.goBack = { [weak web] in web?.goBack() }
        model.goForward = { [weak web] in web?.goForward() }
        model.reload = { [weak web] in web?.reload() }
        model.stopLoading = { [weak web] in web?.stopLoading() }
        model.pushConfigToPage = { [weak self] in self?.pushConfig() }
        model.restoreOriginalInPage = { [weak self] in self?.runInWorld("if (window.__mazemaze) { window.__mazemaze.restoreAll(); }") }
    }

    // MARK: URL changes (including single-page-app route changes that never "navigate")
    private func urlChanged(_ web: WKWebView) {
        let url = web.url
        model.currentURL = url
        if let url { model.addressText = url.absoluteString }
        // Fragment-only changes (#section) are the same page. Anything else is a new page: older
        // requests become stale and the page script starts over.
        guard Self.withoutFragment(url) != Self.withoutFragment(lastURL) else { return }
        lastURL = url
        Task { @MainActor in
            await model.pageWillChange()      // bump the generation first ...
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
            let gen = await model.service.generation
            let cfg = model.pageConfig(for: web.url, gen: gen)
            runInWorld("if (window.__mazemaze) { window.__mazemaze.configure(cfg); }", arguments: ["cfg": cfg])
        }
    }

    // MARK: messages from the page script
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.name == "mazemaze", message.frameInfo.isMainFrame, let web = message.webView,
              let pageURL = web.url, message.frameInfo.securityOrigin.host == pageURL.host,
              message.frameInfo.securityOrigin.protocol == pageURL.scheme else {
            return (nil, "not allowed")
        }
        switch BridgeMessage.parse(message.body) {
        case .failure:
            return (nil, "bad message")
        case .success(.ready):
            let gen = await model.service.generation
            return (model.pageConfig(for: pageURL, gen: gen), nil)
        case .success(.translate(let gen, let text)):
            // Re-check on every request: a single-page app may have moved to a denied page.
            guard model.decision(for: pageURL).isAllowed, model.translationEnabled, !model.suspendedForPage else {
                return (["ok": false, "error": "not_allowed", "message": "このページは翻訳しません"], nil)
            }
            return (await model.translate(gen: gen, text: text), nil)
        }
    }

    // MARK: navigation
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        guard scheme == "https" || scheme == "http" || url.absoluteString == "about:blank" else { return .cancel }
        if navigationAction.targetFrame == nil {
            // target=_blank: stay in this one view, but only for a real tap (no script-opened popups).
            if navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A real document load (including a reload of the same URL): new generation, fresh counters,
        // and the "this page shows the original" choice is forgotten. The new document asks for its
        // configuration itself once it is ready.
        model.resetCounters()
        Task { @MainActor in await model.pageWillChange() }
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
        model.lastProblem = "ページを読み込めません（\(e.localizedDescription)）"
    }

    private var lastCrashReload = Date.distantPast
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload once; a page that keeps crashing must not put the app in a reload loop.
        guard Date().timeIntervalSince(lastCrashReload) > 15 else {
            model.lastProblem = "このページは表示中に異常終了しました"
            return
        }
        lastCrashReload = Date()
        webView.reload()
    }
}
