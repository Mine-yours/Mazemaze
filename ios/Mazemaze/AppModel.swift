import SwiftUI
import WebKit
import MazemazeCore

/// Owns settings, the translation service and what the toolbar shows. Page text only ever flows
/// WebView -> (validated) -> TranslationService -> the Mac server on the local network.
@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let transport: HTTPTransport
    let service: TranslationService
    var sitePolicy: SitePolicy

    // Browser state (updated by the WebView coordinator)
    @Published var addressText = ""
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var pageTitle = ""

    // Translation state
    @Published var translationEnabled: Bool { didSet { settings.translationEnabled = translationEnabled; configChanged() } }
    @Published var ratio: Double { didSet { settings.ratio = ratio; configChanged() } }
    @Published var unit: TranslationUnit { didSet { settings.unit = unit; configChanged() } }
    @Published var suspendedForPage = false          // "原文に戻す" pressed: off for this page only
    @Published var siteStatus = "翻訳: 待機中"
    @Published var inflight = 0
    @Published var okCount = 0
    @Published var failCount = 0
    @Published var lastProblem: String?
    @Published var allowedHosts: [String]

    /// Set by the WebView coordinator.
    var pushConfigToPage: (() -> Void)?
    var restoreOriginalInPage: (() -> Void)?
    var loadURL: ((URL) -> Void)?
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
    var reload: (() -> Void)?
    var stopLoading: (() -> Void)?

    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let debugAllowLocalhost = arg("-MazemazeAllowLocalhost") == "1"
        let defaults: UserDefaults = arg("-MazemazeSelfTest") == "1" ? UserDefaults(suiteName: "mazemaze.selftest")! : .standard
        if arg("-MazemazeSelfTest") == "1" { defaults.removePersistentDomain(forName: "mazemaze.selftest") }
        let secrets: SecretStore = arg("-MazemazeSelfTest") == "1" ? InMemorySecretStore(token: arg("-MazemazeToken")) : KeychainSecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        if let api = arg("-MazemazeAPI") { store.serverURLString = api }
        if arg("-MazemazeSelfTest") != "1", let t = arg("-MazemazeToken") { try? store.setToken(t) }
        #else
        let debugAllowLocalhost = false
        let store = SettingsStore(secrets: KeychainSecretStore())
        #endif
        settings = store
        transport = URLSessionTransport()
        translationEnabled = store.translationEnabled
        ratio = store.ratio
        unit = store.unit
        allowedHosts = store.allowedHosts
        sitePolicy = SitePolicy(allowedHosts: store.allowedHosts, allowInsecureLocalhost: debugAllowLocalhost)
        let s = store
        service = TranslationService(transport: transport,
                                     config: { s.serverConfig() },
                                     prefs: { (s.ratio, s.unit) })
    }

    // MARK: settings changes
    func configChanged() {
        Task {
            await service.configurationChanged()
            pushConfigToPage?()
        }
    }

    func serverSettingsChanged() { configChanged() }

    func setAllowedHosts(_ hosts: [String]) {
        let cleaned = hosts.compactMap(SitePolicy.normalizeEntry)
        settings.allowedHosts = cleaned
        allowedHosts = settings.allowedHosts
        sitePolicy.allowedHosts = allowedHosts
        configChanged()
    }

    // MARK: page <-> native
    /// The decision for the page that is currently shown. Always derived from the WebView's real URL.
    func decision(for url: URL?) -> SiteDecision { sitePolicy.decision(for: url) }

    func pageConfig(for url: URL?, gen: Int) -> [String: Any] {
        let d = decision(for: url)
        var enabled = false
        var profile = "generic"
        switch d {
        case .allowed(let p):
            profile = p.rawValue
            enabled = translationEnabled && !suspendedForPage && settings.serverConfig() != nil
            if !translationEnabled { siteStatus = "翻訳: オフ" }
            else if suspendedForPage { siteStatus = "翻訳: このページは原文表示" }
            else if settings.serverConfig() == nil { siteStatus = "翻訳: サーバー未設定（設定で入力）" }
            else { siteStatus = "翻訳: オン" }
        case .denied(let reason):
            siteStatus = "翻訳しないページ: \(reason)"
        }
        return ["gen": gen, "enabled": enabled, "profile": profile]
    }

    func translate(gen: Int, text: String) async -> [String: Any] {
        inflight += 1
        let outcome = await service.translate(gen: gen, text: text)
        inflight = max(0, inflight - 1)
        switch outcome {
        case .success:
            okCount += 1
            lastProblem = nil
        case .failure(let f):
            switch f {
            case .stale, .cancelled: break
            default:
                failCount += 1
                lastProblem = f.message
                siteStatus = "翻訳: " + f.message
            }
        }
        return outcome.bridgePayload()
    }

    func resetCounters() { okCount = 0; failCount = 0; lastProblem = nil }

    func pageWillChange() async {
        suspendedForPage = false
        _ = await service.bumpGeneration()
    }

    func restoreOriginal() {
        suspendedForPage = true
        siteStatus = "このページは原文を表示中（もう一度翻訳するには「再翻訳」）"
        restoreOriginalInPage?()
    }

    func resumeTranslation() {
        suspendedForPage = false
        Task { _ = await service.bumpGeneration(); pushConfigToPage?() }
    }

    /// First launch: nothing works until the server is set, so open the settings.
    var needsSetup: Bool { settings.serverConfig() == nil }

    func checkConnection() async -> ConnectionReport {
        await ConnectionChecker.check(config: settings.serverConfig(), transport: transport)
    }

    static func normalizeAddress(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("://") { return URL(string: t) }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t) { return u }
        var c = URLComponents(string: "https://duckduckgo.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: t)]
        return c?.url
    }
}
