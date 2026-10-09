import SwiftUI
import WebKit
import MazemazeCore

/// Owns the settings, the shared translation service and the list of tabs. Page text only ever flows
/// WebView -> (validated) -> TranslationService -> the Mac server on the local network.
@MainActor
final class AppModel: ObservableObject {
    static let maxTabs = TabsSnapshot.maxTabs
    static let maxLiveTabs = 4              // more tabs than this sleep (their web views are released)

    let settings: SettingsStore
    let urlTransport: URLSessionTransport
    var transport: HTTPTransport { urlTransport }
    let resolver: EndpointResolver
    let service: TranslationService
    var sitePolicy: SitePolicy
    private let usesDebugArgs: Bool
    #if DEBUG
    private var persistProbeMode: String?
    private var demoTabs = 0
    #endif

    // Tabs
    @Published private(set) var tabs: [TabModel] = []
    @Published private(set) var activeID = 0
    @Published var tabNotice: String?
    private var nextTabID = 1
    private var persistTask: Task<Void, Never>?

    // Translation settings (shared by every tab). Only a real change resets pages and the cache.
    @Published var translationEnabled: Bool { didSet { if oldValue != translationEnabled { settings.translationEnabled = translationEnabled; configChanged() } } }
    @Published var ratio: Double { didSet { if oldValue != ratio { settings.ratio = ratio; configChanged() } } }
    @Published var unit: TranslationUnit { didSet { if oldValue != unit { settings.unit = unit; configChanged() } } }
    @Published var allowedHosts: [String]

    // Home screen
    @Published private(set) var bookmarks: BookmarkData
    private let bookmarkStorage: BookmarkStorage
    @Published var connection: ConnectionReport?
    @Published var checkingConnection = false
    @Published var pendingPairing: PairingPayload?       // waiting for the person's confirmation
    @Published var pairingError: String?
    @Published var pairingResult: String?
    @Published var pairingNonce = 0                      // bumps on every incoming pairing (even if the state looks the same)
    @Published var pairingPromptVisible = false          // the alert may appear only after open sheets have been closed
    private var suppressPersistUntilChange = false
    @Published var restoreTabsEnabled: Bool { didSet { settings.restoreTabs = restoreTabsEnabled; if !restoreTabsEnabled { settings.savedTabsData = nil } else { tabsChanged() } } }
    @Published var recentsEnabled: Bool { didSet { settings.recentsEnabled = recentsEnabled; if !recentsEnabled { clearRecents() } } }

    var active: TabModel { tabs.first { $0.id == activeID } ?? tabs[0] }

    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let debugAllowLocalhost = arg("-MazemazeAllowLocalhost") == "1"
        // Launch arguments are for tests only. They must never overwrite the settings of a real
        // installation (a leftover test server URL looks exactly like "the server is down"), so a
        // run that uses them gets throw-away defaults and an in-memory token.
        let persistProbe = arg("-MazemazePersistTest")          // write/read the REAL stores across launches (test device only)
        let usesDebugArgs = persistProbe == nil && (arg("-MazemazeSelfTest") == "1" || arg("-MazemazeAPI") != nil || arg("-MazemazeToken") != nil)
        let defaults: UserDefaults = usesDebugArgs ? UserDefaults(suiteName: "mazemaze.debugargs")! : .standard
        if usesDebugArgs { defaults.removePersistentDomain(forName: "mazemaze.debugargs") }
        let secrets: SecretStore = usesDebugArgs ? InMemorySecretStore(token: arg("-MazemazeToken")) : KeychainSecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        if let api = arg("-MazemazeAPI") { store.serverURLString = api }
        let initialURL = arg("-MazemazeInitialURL").flatMap(URL.init(string:))
        self.demoTabs = Int(arg("-MazemazeDemoTabs") ?? "") ?? 0
        self.persistProbeMode = persistProbe
        #else
        let usesDebugArgs = false
        let debugAllowLocalhost = false
        let store = SettingsStore(secrets: KeychainSecretStore())
        let initialURL: URL? = nil
        #endif
        self.usesDebugArgs = usesDebugArgs
        settings = store
        let urlTransport = URLSessionTransport()
        self.urlTransport = urlTransport
        resolver = EndpointResolver(transport: urlTransport)
        translationEnabled = store.translationEnabled
        ratio = store.ratio
        unit = store.unit
        allowedHosts = store.allowedHosts
        restoreTabsEnabled = store.restoreTabs
        recentsEnabled = store.recentsEnabled
        sitePolicy = SitePolicy(allowedHosts: store.allowedHosts, allowInsecureLocalhost: debugAllowLocalhost)
        bookmarkStorage = BookmarkStorage(defaults: store.userDefaults)
        bookmarks = bookmarkStorage.load()
        let s = store
        service = TranslationService(transport: urlTransport,
                                     config: { s.serverConfig() },
                                     prefs: { (s.ratio, s.unit) },
                                     resolver: resolver)
        syncPins()
        startTabs(initialURL: initialURL)
        Task { [service, id = activeID] in await service.setActiveScope(id) }
        #if DEBUG
        if let mode = persistProbeMode { Task { @MainActor in self.runPersistProbe(mode) } }
        if demoTabs > 0 {      // screenshots only: a few sleeping tabs
            let urls = ["https://news.yahoo.co.jp/articles/demo", "https://www3.nhk.or.jp/news/", "https://example.com/blog/a", "https://example.org/b"]
            for i in 0..<min(demoTabs, urls.count) { tabs.append(makeTab(url: URL(string: urls[i]), title: i == 0 ? "シャウエッセン、6本から5本へ…はなぜ炎上？" : nil)) }
        }
        #endif
    }

    #if DEBUG
    /// Used by ios/scripts/persistence_test.sh: proves what survives an app restart / update / reinstall.
    private func runPersistProbe(_ mode: String) {
        let fp = String(repeating: "ab", count: 32)
        if mode == "write" {
            settings.serverURLString = "https://persist-test.local:8000"
            try? settings.setToken("persist-token-abcdef123456")
            settings.pinnedFingerprint = fp
            addFavorite(url: URL(string: "https://example.com/fav"), title: "Fav")
            tabs = [makeTab(url: URL(string: "https://news.yahoo.co.jp/articles/a?token=1"), title: "記事"),
                    makeTab(url: URL(string: "https://mail.example.com/inbox"), title: "受信箱")]
            activeID = tabs[0].id
            persistTabsNow()
            settings.flush()
            print("PERSIST WROTE")
        } else {
            let tabsRestored = TabsSnapshot.restore(from: settings.savedTabsData, allowedHosts: SessionPrivacy.titleHosts)?.tabs.map { $0.url ?? "home" } ?? []
            print("PERSIST READ url=\(settings.serverURLString == "https://persist-test.local:8000" ? "OK" : "MISSING(\(settings.serverURLString))") "
                  + "token=\(settings.token == "persist-token-abcdef123456" ? "OK" : "MISSING") pin=\(settings.pinnedFingerprint == fp ? "OK" : "MISSING") "
                  + "favorites=\(bookmarks.favorites.count) tabs=\(tabsRestored)")
        }
        fflush(stdout)
        exit(0)
    }
    #endif

    // MARK: tabs
    private func makeTab(url: URL? = nil, title: String? = nil) -> TabModel {
        defer { nextTabID += 1 }
        return TabModel(id: nextTabID, app: self, url: url, title: title)
    }

    private func startTabs(initialURL: URL?) {
        #if DEBUG
        if SelfTest.isActive { let t = makeTab(); tabs = [t]; activeID = t.id; t.ensureWebView(); return }
        #endif
        if let initialURL {
            let t = makeTab(); tabs = [t]; activeID = t.id
            t.navigate(to: initialURL)
            return
        }
        if settings.restoreTabs, let snap = TabsSnapshot.restore(from: settings.savedTabsData, allowedHosts: SessionPrivacy.titleHosts) {
            tabs = snap.tabs.map { makeTab(url: $0.url.flatMap(URL.init(string:)), title: $0.title) }
            activeID = tabs[snap.activeIndex].id
            if active.isSleeping { active.ensureWebView() }
            return
        }
        let t = makeTab(); tabs = [t]; activeID = t.id
    }

    /// Open a new tab (on the home screen, or at `url`). Returns nil when the limit is reached.
    @discardableResult
    func newTab(url: URL? = nil) -> TabModel? {
        guard tabs.count < Self.maxTabs else {
            tabNotice = "タブは最大 \(Self.maxTabs) 個までです。使わないタブを閉じてください"
            return nil
        }
        let t = makeTab()
        tabs.append(t)
        activate(t.id)
        if let url { t.navigate(to: url) }
        return t
    }

    func activate(_ id: Int) {
        guard let new = tabs.first(where: { $0.id == id }) else { return }
        if new.id != activeID, let old = tabs.first(where: { $0.id == activeID }) { old.pauseInPage?() }
        activeID = id
        new.lastActive = Date()
        Task { await service.setActiveScope(id) }
        if new.isSleeping { new.ensureWebView() } else { new.resumeInPage?() }   // switching never reloads a live tab
        enforceLiveLimit()
        tabsChanged()
    }

    func closeTab(_ id: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tab.close()
        Task { await service.removeScope(id) }
        tabs.remove(at: index)
        if tabs.isEmpty {
            let t = makeTab(); tabs = [t]; activate(t.id)
        } else if id == activeID {
            activate(tabs[min(index, tabs.count - 1)].id)
        }
        tabsChanged()
    }

    /// Release web views of the tabs used least recently (the tab on screen is never released).
    func enforceLiveLimit() {
        let live = tabs.filter { $0.webView != nil }
        guard live.count > Self.maxLiveTabs else { return }
        let victims = live.filter { $0.id != activeID }.sorted { $0.lastActive < $1.lastActive }.prefix(live.count - Self.maxLiveTabs)
        for v in victims { v.hibernate() }
    }

    func tabsChanged() {
        suppressPersistUntilChange = false
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistTabs()
        }
    }

    func persistTabsNow() { if !suppressPersistUntilChange { persistTabs() } }

    private func persistTabs() {
        guard !usesDebugArgs else { return }
        guard settings.restoreTabs else { settings.savedTabsData = nil; return }
        let activeIndex = tabs.firstIndex { $0.id == activeID } ?? 0
        let snap = TabsSnapshot.make(tabs: tabs.map { $0.persistTarget }, activeIndex: activeIndex, allowedHosts: SessionPrivacy.titleHosts)
        settings.savedTabsData = snap.encoded()
        settings.flush()
    }

    // MARK: settings changes
    func configChanged() {
        Task {
            await service.configurationChanged()
            for t in tabs { t.pushConfigToPage?() }
        }
    }

    func serverSettingsChanged() { syncPins(); configChanged() }

    /// The certificate each paired server must present (empty when the server is not paired over https).
    func syncPins() {
        var pins: [String: String] = [:]
        if let cfg = settings.serverConfig(), let fp = cfg.pinnedFingerprint {
            for url in cfg.candidates { if let host = url.host { pins[host.lowercased()] = fp } }
        }
        urlTransport.setPins(pins)
    }

    // MARK: pairing (QR code or pasted text from the Mac)
    /// Parse what the camera / clipboard gave us. Nothing is applied until the person confirms.
    func receivePairing(_ raw: String) {
        pairingResult = nil
        pairingPromptVisible = false
        switch PairingPayload.parse(raw) {
        case .success(let p): pairingError = nil; pendingPairing = p
        case .failure(let e): pendingPairing = nil; pairingError = e.message
        }
        pairingNonce += 1          // the screen closes any sheet, waits a moment, then shows the prompt
    }

    func cancelPairing() { pendingPairing = nil; pairingPromptVisible = false }

    func confirmPairing() {
        guard let p = pendingPairing else { return }
        pendingPairing = nil
        pairingPromptVisible = false
        do {
            try settings.apply(p)
        } catch {
            pairingError = "ペアリングを保存できませんでした（キーチェーンまたは設定）。"
            return
        }
        pairingError = nil
        serverSettingsChanged()
        Task {
            var report = await checkConnection()
            if report.state == .failed {
                // The first request after the local-network permission dialog often fails: try once more.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let again = await checkConnection()
                if again.state != .failed { report = again }
            }
            connection = report
            pairingResult = report.state == .ok ? "ペアリングしました。" + report.message : "保存しました。ただし確認で問題がありました: " + report.message + "（ホーム画面の「もう一度確認」で再確認できます）"
            if report.state == .ok { active.recoverIfNeeded(); warmupIfNeeded() }
        }
    }

    func setAllowedHosts(_ hosts: [String]) {
        let cleaned = hosts.compactMap(SitePolicy.normalizeEntry)
        settings.allowedHosts = cleaned
        allowedHosts = settings.allowedHosts
        sitePolicy.allowedHosts = allowedHosts
        configChanged()
    }

    /// The decision for a page. Always derived from a WebView's real URL.
    func decision(for url: URL?) -> SiteDecision { sitePolicy.decision(for: url) }

    /// Add the host of the page to the sites that get translated.
    @discardableResult
    func allowTranslation(on url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), let entry = SitePolicy.normalizeEntry(host) else { return false }
        if !allowedHosts.contains(entry) { setAllowedHosts(allowedHosts + [entry]) }
        return true
    }

    // MARK: home screen: favorites and recent sites
    var activeIsFavorite: Bool { active.currentURL.map { bookmarks.isFavorite($0) } ?? false }

    @discardableResult
    func addFavorite(url: URL?, title: String) -> Bool {
        guard let url else { return false }
        var copy = bookmarks
        guard copy.addFavorite(url: url, title: title) else { return false }
        bookmarks = copy; bookmarkStorage.save(copy)
        return true
    }

    func removeFavorite(id: UUID) {
        var copy = bookmarks; copy.removeFavorite(id: id)
        bookmarks = copy; bookmarkStorage.save(copy)
    }

    func recordVisit(of tab: TabModel) {
        guard recentsEnabled, tab.webView != nil else { return }
        var copy = bookmarks
        copy.recordVisit(url: tab.currentURL, title: tab.pageTitle, allowedHosts: SessionPrivacy.titleHosts)
        if copy != bookmarks { bookmarks = copy; bookmarkStorage.save(copy) }
    }

    func clearRecents() {
        var copy = bookmarks; copy.clearRecents()
        bookmarks = copy; bookmarkStorage.save(copy)
    }

    /// "履歴を消去": recent sites and the saved tabs. (Cookies and logins of web sites are not touched.)
    func clearHistory() {
        persistTask?.cancel()
        clearRecents()
        settings.savedTabsData = nil           // tabs that are open now are saved again after the next navigation
        suppressPersistUntilChange = true      // ... not by the "app went to the background" save
        settings.flush()
    }

    // MARK: misc
    /// Wake the model on the Mac in the background (it takes seconds when it has been idle).
    func warmupIfNeeded() {
        guard settings.serverConfig() != nil else { return }
        Task { _ = await service.warmupIfStale() }
    }

    /// Hands a URL to Safari / another app. Only ever called from a button the user pressed.
    func openOutside(_ url: URL) { UIApplication.shared.open(url) }

    /// First launch: nothing works until the server is set, so open the settings.
    var needsSetup: Bool { settings.serverConfig() == nil }

    func checkConnection() async -> ConnectionReport {
        await ConnectionChecker.check(config: settings.serverConfig(), transport: transport, resolver: resolver)
    }

    func refreshConnectionStatus() {
        guard !checkingConnection else { return }
        checkingConnection = true
        Task {
            connection = await checkConnection()
            checkingConnection = false
        }
    }
}
