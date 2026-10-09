import SwiftUI
import WebKit
import MazemazeCore

/// A navigation the in-app browser deliberately did not perform (shown instead of a blank page).
struct BlockedNavigation: Equatable {
    enum Kind: Equatable { case safariRedirect, otherApp }
    let kind: Kind
    let openURL: URL
    let host: String
}

enum ProblemAction: Equatable { case openSettings, reload }

/// One browser tab: its page state, its web view (created on demand, dropped when the tab sleeps) and
/// its own translation scope. Everything a page shows in the toolbar lives here; settings and the
/// translation service are shared through `AppModel`.
@MainActor
final class TabModel: ObservableObject, Identifiable {
    /// `.web`: an ordinary browser tab. `.paste`: the "貼り付けて翻訳" result page: not in the tab list, never
    /// saved or restored, its text lives only in memory.
    enum Kind { case web, paste }

    let id: Int
    let kind: Kind
    let pasteLines: [String]
    unowned let app: AppModel

    // What the screen shows
    @Published var addressText = ""
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var pageTitle = ""
    @Published var blockedNavigation: BlockedNavigation? { didSet { if blockedNavigation != nil { revealBars() } } }
    @Published var suspendedForPage = false          // "原文に戻す" pressed: off for this page only
    @Published var siteStatus = "翻訳: 待機中"
    @Published var inflight = 0
    @Published var okCount = 0
    @Published var failCount = 0
    @Published var lastProblem: String? { didSet { if lastProblem != nil { revealBars() } } }   // needs the user to do something (red)
    @Published var problemAction: ProblemAction?
    @Published var notice: String? { didSet { if notice != nil { revealBars() } } }   // recovers by itself (orange): Mac busy, paused
    @Published private(set) var webView: WKWebView?
    @Published private(set) var restoreURL: URL?     // where a sleeping tab continues
    @Published var restoredTitle: String?
    @Published private(set) var barsHidden = false   // the address bar / toolbar have slid away (reading)
    private var bars = BarVisibility()
    var lastActive = Date()
    private(set) var coordinator: BrowserCoordinator?

    /// Set by the coordinator while a web view exists.
    var pushConfigToPage: (() -> Void)?
    var restoreOriginalInPage: (() -> Void)?
    var pauseInPage: (() -> Void)?
    var resumeInPage: (() -> Void)?
    var loadURL: ((URL) -> Void)?
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
    var reload: (() -> Void)?
    var stopLoading: (() -> Void)?

    init(id: Int, app: AppModel, url: URL? = nil, title: String? = nil, kind: Kind = .web, pasteLines: [String] = []) {
        self.id = id; self.app = app; self.kind = kind; self.pasteLines = pasteLines
        restoreURL = url; restoredTitle = title
        if let url { addressText = url.absoluteString; currentURL = url }
    }

    // MARK: bars that slide away while reading
    /// Every change of the page's scroll position. `minOffset` is the offset at the very top.
    func scrolled(offset: Double, minOffset: Double, userDriven: Bool) {
        guard app.settings.autoHideBars, !UIAccessibility.isVoiceOverRunning, !showsHome, blockedNavigation == nil, lastProblem == nil else {
            if barsHidden { revealBars() }
            return
        }
        if bars.update(offset: offset, minOffset: minOffset, now: ProcessInfo.processInfo.systemUptime, userDriven: userDriven) { barsHidden = bars.hidden }
    }

    func revealBars() {
        bars.reveal(now: ProcessInfo.processInfo.systemUptime)
        if barsHidden { barsHidden = false }
    }

    /// A different page is shown: start with the bars visible.
    func resetBars() { bars.reset(); if barsHidden { barsHidden = false } }

    // MARK: state of the tab
    /// The home screen is shown while the tab has neither a page nor a place to continue from.
    var showsHome: Bool { webView == nil && restoreURL == nil }
    var isSleeping: Bool { webView == nil && restoreURL != nil }
    var displayTitle: String {
        if showsHome { return "ホーム" }
        let t = pageTitle.isEmpty ? (restoredTitle ?? "") : pageTitle
        return t.isEmpty ? ((currentURL ?? restoreURL)?.host ?? "新しいタブ") : t
    }
    var displayHost: String { (currentURL ?? restoreURL)?.host ?? "" }
    /// What may be saved about this tab (SessionPrivacy decides later).
    var persistTarget: (url: URL?, title: String?) { (currentURL ?? restoreURL, pageTitle.isEmpty ? restoredTitle : pageTitle) }

    // MARK: web view life cycle
    /// The web view for this tab; created (and the saved page loaded) the first time it is needed.
    @discardableResult
    func ensureWebView(loading url: URL? = nil) -> WKWebView {
        if let webView { if let url { loadURL?(url) }; return webView }
        let coordinator = BrowserCoordinator(tab: self, app: app)
        self.coordinator = coordinator
        let target = url ?? restoreURL
        let web = coordinator.makeWebView(initialURL: target)
        webView = web
        restoreURL = nil
        app.enforceLiveLimit()           // a web view was just added: keep the number of live ones bounded
        return web
    }

    /// Navigate this tab (a tab on the home screen gets its web view now).
    func navigate(to url: URL) {
        if webView == nil { ensureWebView(loading: url) } else { loadURL?(url) }
        addressText = url.absoluteString
    }

    /// Give the memory back: remember where we were, drop the web view and everything attached to it.
    func hibernate() {
        guard let web = webView else { return }
        _ = web
        restoreURL = currentURL ?? web.url
        restoredTitle = pageTitle.isEmpty ? restoredTitle : pageTitle
        coordinator?.teardown()
        coordinator = nil
        webView = nil
        pushConfigToPage = nil; restoreOriginalInPage = nil; pauseInPage = nil; resumeInPage = nil
        loadURL = nil; goBack = nil; goForward = nil; reload = nil; stopLoading = nil
        isLoading = false; progress = 0; canGoBack = false; canGoForward = false
        blockedNavigation = nil
        resetBars()
        resetCounters(); inflight = 0
        suspendedForPage = false
        Task { [id, app] in _ = await app.service.bumpGeneration(scope: id) }      // a sleeping tab must not keep a place in the queue
    }

    /// Closing the tab: stop everything it owns.
    func close() {
        coordinator?.teardown()
        coordinator = nil
        webView = nil
    }

    func goHomeScreen() {
        coordinator?.teardown()
        coordinator = nil
        webView = nil
        restoreURL = nil; restoredTitle = nil
        currentURL = nil; addressText = ""; pageTitle = ""
        pushConfigToPage = nil; restoreOriginalInPage = nil; pauseInPage = nil; resumeInPage = nil
        loadURL = nil; goBack = nil; goForward = nil; reload = nil; stopLoading = nil
        isLoading = false; progress = 0; canGoBack = false; canGoForward = false
        blockedNavigation = nil; resetCounters(); inflight = 0; suspendedForPage = false
        resetBars()
        Task { [id, app] in _ = await app.service.bumpGeneration(scope: id) }      // the closed page must not keep a place in the queue
        app.tabsChanged()
    }

    // MARK: page <-> native (one page of this tab)
    func pageConfig(for url: URL?, gen: Int) -> [String: Any] {
        let d = app.decision(for: url)
        var enabled = false
        var profile = "generic"
        switch d {
        case .allowed(let p):
            profile = p.rawValue
            enabled = app.translationEnabled && !suspendedForPage && app.settings.serverConfig() != nil
            if !app.translationEnabled { siteStatus = "翻訳: オフ" }
            else if suspendedForPage { siteStatus = "翻訳: このページは原文表示" }
            else if app.settings.serverConfig() == nil { siteStatus = "翻訳: サーバー未設定（設定で入力）" }
            else { siteStatus = "翻訳: オン" }
        case .denied(let reason):
            siteStatus = "翻訳しないページ: \(reason)"
        }
        return ["gen": gen, "enabled": enabled, "profile": profile]
    }

    func translate(gen: Int, text: String) async -> [String: Any] {
        inflight += 1
        let outcome = await app.service.translate(scope: id, gen: gen, text: text)
        inflight = max(0, inflight - 1)
        switch outcome {
        case .success:
            okCount += 1
            if siteStatus.contains("翻訳できる本文が見つかりません") { siteStatus = "翻訳: オン" }
            lastProblem = nil
            problemAction = nil
            notice = nil
        case .failure(let f):
            switch f {
            case .stale, .cancelled:
                break
            case .busy:
                notice = "Mac が他の翻訳を処理中です。空き次第、自動で続きます"
            case .breakerOpen(let secs):
                let detail = await app.service.lastErrorDetail
                notice = "翻訳サーバーのエラーが続いたため、約 \(secs) 秒お待ちください（自動で再開します）" + (detail.map { "［\($0)］" } ?? "")
            default:
                failCount += 1
                let detail = await app.service.lastErrorDetail
                var text = f.message
                switch f {
                case .unreachable, .timeout, .server, .invalidResponse:
                    if let c = app.settings.serverConfig() {
                        text += "（接続先: \(c.baseURL.host ?? "?"):\(c.baseURL.port ?? 80)\(detail.map { "・" + $0 } ?? "")）"
                    }
                default: break
                }
                lastProblem = text
                switch f {
                case .unauthorized, .notConfigured, .unreachable, .pinMismatch, .certificateUntrusted: problemAction = .openSettings
                default: problemAction = nil
                }
                siteStatus = "翻訳: エラー"
            }
        }
        return outcome.bridgePayload()
    }

    /// Close the card. The page underneath never changed, so restore what it shows (address, status)
    /// and re-send its configuration.
    func dismissBlockedNavigation() {
        guard blockedNavigation != nil else { return }
        blockedNavigation = nil
        if let u = currentURL { addressText = u.absoluteString }
        pushConfigToPage?()
    }

    func resetCounters() { okCount = 0; failCount = 0; lastProblem = nil; problemAction = nil; notice = nil }

    /// Back in the foreground (or the connection check succeeded): forget past failures and start over.
    func recoverIfNeeded() {
        // Only for trouble that a fresh start can fix (connection / settings), not for page-load errors.
        guard problemAction == .openSettings || notice != nil else { return }
        Task {
            await app.service.clearFailures()
            pushConfigToPage?()
        }
    }

    func pageWillChange() async {
        suspendedForPage = false
        _ = await app.service.bumpGeneration(scope: id)
    }

    func restoreOriginal() {
        suspendedForPage = true
        siteStatus = "このページは原文を表示中（もう一度翻訳するには「再翻訳」）"
        restoreOriginalInPage?()
    }

    func resumeTranslation() {
        suspendedForPage = false
        Task { _ = await app.service.bumpGeneration(scope: id); pushConfigToPage?() }
    }
}
