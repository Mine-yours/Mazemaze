import SwiftUI
import MazemazeCore

/// Apple's translation session only exists inside a view, so a 1-point invisible view stays in the window (see DeviceEngines.swift).
struct AppleTranslationHostContainer: View {
    let model: AppModel
    var body: some View {
        if #available(iOS 18.0, *), let host = model.deviceEngines.appleHost { AppleTranslationHostView(host: host) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var showTabs = false
    @State private var showDictionary = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        PageScreen(tab: model.active, showSettings: $showSettings, showTabs: $showTabs, showDictionary: $showDictionary)
            .id(model.activeID)
            .background { AppleTranslationHostContainer(model: model) }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
            .sheet(isPresented: $showTabs) { TabSwitcherView().environmentObject(model) }
            .sheet(isPresented: $showDictionary) { DictionaryView().environmentObject(model) }
            .sheet(item: Binding(get: { model.showPaste ? nil : model.lookupSession }, set: { model.lookupSession = $0 })) { LookupSheet(session: $0).environmentObject(model) }
            .fullScreenCover(isPresented: $model.showPaste) { PasteTranslateView().environmentObject(model) }
            .onAppear {
                #if DEBUG
                // Screenshots only (simulator): open a sheet from a launch argument.
                switch SelfTest.value("-MazemazeShow") {
                case "tabs"?: showTabs = true; return
                case "settings"?: showSettings = true; return
                case "lookup"?, "lookupphrase"?:             // screenshots only
                    let phrase = SelfTest.value("-MazemazeShow") == "lookupphrase"
                    if let r = LookupRequest.make(kind: phrase ? .phrase : .word, term: phrase ? "I have a pen" : "have", contextEnglish: "I have a pen", contextJapanese: "ペンを持っています") {
                        Task { @MainActor in try? await Task.sleep(nanoseconds: 800_000_000); model.openLookup(r, pageURL: URL(string: "https://x.com/a")) }
                    }
                    return
                case "dictionary"?:
                    if SelfTest.value("-MazemazeDemoDictionary") == "1" {      // screenshots only
                        for (en, ja, src) in [("good weather", "良い天気", "news.yahoo.co.jp"), ("Prime Minister", "首相", "x.com"), ("take a stroll", "散歩に出かける", DictionaryData.pasteSource)] {
                            _ = model.saveToDictionary(english: en, japanese: ja, pageURL: src == DictionaryData.pasteSource ? PasteSurface.url : URL(string: "https://\(src)/a"))
                        }
                    }
                    if SelfTest.value("-MazemazeDemoDictionary") == "1", let r1 = LookupRequest.make(kind: .word, term: "have", contextEnglish: "I have lunch at noon", contextJapanese: "正午に昼食を食べます"),
                       let r2 = LookupRequest.make(kind: .word, term: "stroll", contextEnglish: "She took a stroll along the river", contextJapanese: "彼女は川沿いを散歩した") {
                        let s1 = LookupSession(request: r1, source: "x.com", sourceURL: nil, existingEntry: nil)
                        _ = model.saveWordWithContext(request: r1, session: s1)                                  // waiting for its meaning
                        let json: [String: Any] = ["card": ["kind": "word", "lemma": "stroll", "pos": "名詞", "contextMeaning": "散歩", "contextIndex": 0, "meanings": [["meaning": "散歩"], ["meaning": "ぶらぶら歩く"]]]]
                        if let data = try? JSONSerialization.data(withJSONObject: json), let card = DefinitionCard.decode(serverResponse: data) {
                            _ = model.saveLookedUp(card: card, request: r2, session: LookupSession(request: r2, source: "news.yahoo.co.jp", sourceURL: nil, existingEntry: nil))
                        }
                    }
                    showDictionary = true; return
                default: break
                }
                // Stress: open the tab list while a translation is running, then pick another tab.
                if let n = SelfTest.value("-MazemazeShowLoop").flatMap(Int.init) {
                    Task { @MainActor in
                        for _ in 0..<n {
                            try? await Task.sleep(nanoseconds: 1_300_000_000); showTabs = true
                            try? await Task.sleep(nanoseconds: 1_300_000_000); showTabs = false
                        }
                    }
                }
                if let after = SelfTest.value("-MazemazeShowAfter").flatMap(Double.init) {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000)); showTabs = true
                        if let pick = SelfTest.value("-MazemazePickAfter").flatMap(Double.init) {
                            try? await Task.sleep(nanoseconds: UInt64(pick * 1_000_000_000))
                            if let other = model.tabs.first(where: { $0.id != model.activeID }) { model.activate(other.id) }
                            showTabs = false
                        }
                    }
                }
                #endif
                model.refreshEngineStatus()
                model.startMeaningWorker()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.refreshEngineStatus(); model.active.recoverIfNeeded(); model.pasteTab?.recoverIfNeeded(); model.reloadDictionaryIfNeeded(); model.startMeaningWorker() }
                if phase == .background { model.persistTabsNow() }          // the 0.8 s delayed save may not get to run
            }
            .onChange(of: model.pasteNonce) { _ in
                // A full-screen cover cannot appear above an open sheet: close them first.
                let hadSheet = showSettings || showTabs || showDictionary || model.lookupSession != nil
                showSettings = false; showTabs = false; showDictionary = false; model.lookupSession = nil
                Task { @MainActor in
                    if hadSheet { try? await Task.sleep(nanoseconds: 500_000_000) }
                    model.presentPaste()
                }
            }
            .alert("タブ", isPresented: Binding(get: { model.tabNotice != nil }, set: { if !$0 { model.tabNotice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.tabNotice ?? "") }
    }
}

/// One tab on screen: address bar, page (or the home screen), status line and the toolbar.
struct PageScreen: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @Binding var showTabs: Bool
    @Binding var showDictionary: Bool
    @FocusState private var addressFocused: Bool
    @State private var showProblemDetail = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var addressError: String?

    @State private var bottomH: CGFloat = 0           // address bar + toolbar (what the page is laid out around)
    @State private var bottomFullH: CGFloat = 0       // ... plus the attention strip (what has to slide away)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if tab.showsHome { homeLayout } else { readingLayout }
        }
        .alert("エラーの内容", isPresented: $showProblemDetail) { Button("OK", role: .cancel) {} } message: { Text(tab.lastProblem ?? "") }
    }

    /// Home screen: the bars stay put. The address bar sits just above the toolbar (thumb reach, and a page that does
    /// not scroll keeps its top free).
    private var homeLayout: some View {
        VStack(spacing: 0) {
            HomeView(tab: tab, showSettings: $showSettings)
            attentionStrip
            addressBar.background(.bar)
            if !addressFocused { toolbar }
        }
    }

    /// A page: it fills the screen and is laid out around the bottom bars (address bar + toolbar); they slide away
    /// while reading.
    private var readingLayout: some View {
        GeometryReader { geo in
            let hidden = tab.barsHidden
            ZStack {
                BrowserView(tab: tab, covered: UIEdgeInsets(top: 0, left: 0, bottom: hidden ? 0 : bottomH, right: 0))
                    .ignoresSafeArea()
                if let blocked = tab.blockedNavigation {
                    blockedCard(blocked).padding(.bottom, bottomH)
                }
                // Keep the clock readable: the page scrolls under the status bar.
                VStack(spacing: 0) {
                    Rectangle().fill(.bar).frame(height: geo.safeAreaInsets.top)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        attentionStrip                       // floats over the page: its height is not part of the layout
                        VStack(spacing: 0) {
                            addressBar.background(.bar)
                            if !addressFocused { toolbar }
                        }
                        .background(GeometryReader { Color.clear.preference(key: BarHeightKey.self, value: ["bottom": $0.size.height]) })
                    }
                    .background(GeometryReader { Color.clear.preference(key: BarHeightKey.self, value: ["bottomFull": $0.size.height]) })
                    .offset(y: hidden ? max(bottomH, bottomFullH) + geo.safeAreaInsets.bottom + 8 : 0)
                    .allowsHitTesting(!hidden).accessibilityHidden(hidden)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: hidden)
                // A page's own keyboard must not push our bars up; the address field's keyboard must (it is down here).
                .ignoresSafeArea(addressFocused ? [] : [.keyboard])
                if hidden { revealHandle }
            }
            .onPreferenceChange(BarHeightKey.self) { v in
                guard !addressFocused else { return }          // typing an address: leave the page's layout alone
                if let b = v["bottom"], abs(b - bottomH) > 0.5 { bottomH = b }
                if let b = v["bottomFull"], abs(b - bottomFullH) > 0.5 { bottomFullH = b }
            }
            .onChange(of: addressFocused) { focused in if focused { tab.revealBars() } }
            #if DEBUG
            .task { if SelfTest.value("-MazemazeFocusAddress") == "1" { try? await Task.sleep(nanoseconds: 6_000_000_000); addressFocused = true } }
            #endif
        }
    }

    /// Shown while the bars are away: one tap brings them back (scrolling up does too).
    private var revealHandle: some View {
        VStack {
            Spacer()
            Button { tab.revealBars() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up").font(.caption.bold())
                    Text(tab.displayHost.isEmpty ? "メニューを表示" : tab.displayHost).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 14).frame(minHeight: 32)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .accessibilityLabel("メニューを表示")
        }
    }


    // MARK: address bar
    private var addressBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TextField("URL または検索語を入力", text: $tab.addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(submitAddress)
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("アドレス欄（URL または検索語）")
                    .overlay(alignment: .trailing) {
                        if addressFocused && !tab.addressText.isEmpty {
                            Button { tab.addressText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                                .accessibilityLabel("入力を消す")
                        }
                    }
                if tab.isLoading {
                    Button { tab.stopLoading?() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                        .accessibilityLabel("読み込みを停止")
                } else if !tab.showsHome {
                    Button { tab.reload?() } label: { Image(systemName: "arrow.clockwise").frame(width: 40, height: 40) }
                        .accessibilityLabel("更新")
                }
            }
            if let e = addressError { Text(e).font(.footnote).foregroundStyle(Color.red) }
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
        .overlay(alignment: .top) {
            if tab.isLoading { ProgressView(value: tab.progress).progressViewStyle(.linear).accessibilityLabel("読み込み中") }
        }
    }

    private func submitAddress() {
        addressFocused = false
        addressError = nil
        switch AddressInput.classify(tab.addressText) {
        case .url(let url): tab.navigate(to: url)
        case .search(let words):
            if let url = AddressInput.searchURL(for: words, engine: model.settings.searchEngine) { tab.navigate(to: url) }
        case .rejected: addressError = "このアドレスは開けません（http / https の URL か、検索したい語句を入力してください）"
        }
    }

    // MARK: blocked navigation card
    /// Shown instead of a blank page when the site refuses the in-app browser or links to another app.
    private func blockedCard(_ b: BlockedNavigation) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: b.kind == .safariRedirect ? "safari" : "arrow.up.forward.app").font(.system(size: 40)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(b.kind == .safariRedirect ? "このサイトはアプリ内ブラウザでは開けません" : "別のアプリで開くリンクです")
                    .font(.headline).multilineTextAlignment(.center)
                Text(b.kind == .safariRedirect
                     ? "\(b.host) は、アプリ内ブラウザからのアクセスを Safari に誘導しています。\(BrowserIdentity.wantsSafariIdentity(host: b.host) ? "このアプリは X に Safari 互換の UA を送る設定ですが、それでも誘導されました（設定でオフにしている可能性があります）。" : "Mazemaze は、X 以外のサイトの制限は回避しません。")Safari で開くことはできますが、翻訳はされません。"
                     : "このリンク（\(b.host)）を開くと、このアプリを離れます。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { model.openOutside(b.openURL); tab.dismissBlockedNavigation() } label: {
                    Text(b.kind == .safariRedirect ? "Safari で開く" : "開く").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                Button { tab.dismissBlockedNavigation() } label: {
                    Text("閉じる（いまのページに残る）").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
                Button { tab.dismissBlockedNavigation(); tab.goHomeScreen() } label: {
                    Text("このタブをホームに戻す").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(.tint)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityAddTraits(.isModal)
    }

    // MARK: attention strip
    /// Only what needs attention: a problem, a notice, or why this page is not translated. (The normal "translating /
    /// N places" status is on the translation button.) It floats over the page, so it never moves the page around.
    private var attentionStrip: some View {
        let info = infoText
        return VStack(alignment: .leading, spacing: 4) {
            if let info {
                Text(info).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let n = tab.notice {
                Label { Text(n).font(.footnote).foregroundStyle(.primary).lineLimit(3) } icon: { Image(systemName: "clock").foregroundStyle(Color.orange) }
            }
            if let p = tab.lastProblem {
                Label { Text(p).font(.footnote).foregroundStyle(.primary).lineLimit(3) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.red) }
                HStack {
                    problemButton
                    if p.count > 70 { Button("詳しく見る") { showProblemDetail = true }.buttonStyle(.bordered).frame(minHeight: 44) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, (info == nil && tab.notice == nil && tab.lastProblem == nil) ? 0 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    /// Why the page is not being translated (or a first-time hint). Nil in the normal case.
    private var infoText: String? {
        guard !tab.showsHome, tab.inflight == 0 else { return nil }
        let s = tab.siteStatus
        if s == "翻訳: オン" || s == "翻訳: 待機中" || s == "翻訳: エラー" { return nil }
        return s
    }

    @ViewBuilder private var problemButton: some View {
        switch tab.problemAction {
        case .openSettings:
            Button("設定を開く") { showSettings = true }.buttonStyle(.bordered).frame(minHeight: 44)
        case .reload:
            Button("再読み込み") { tab.reload?() }.buttonStyle(.bordered).frame(minHeight: 44)
        case nil:
            EmptyView()
        }
    }

    // MARK: toolbar
    private var toolbar: some View {
        HStack {
            barButton("chevron.left", "戻る", "戻る", enabled: tab.canGoBack) { tab.goBack?() }
            barButton("chevron.right", "進む", "進む", enabled: tab.canGoForward) { tab.goForward?() }
            tabsButton
            translateButton
            barButton("character.book.closed", "辞書", "辞書を開く（保存した英語表現 \(model.dictionary.entries.count) 件）", enabled: true) { showDictionary = true }
            moreMenu
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(.bar)
    }

    /// Translation on/off. While translating it shows a spinner; afterwards how many places were turned into English.
    private var translateButton: some View {
        Button {
            if !model.translationEnabled { tab.suspendedForPage = false }
            model.translationEnabled.toggle()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: model.translationEnabled ? "character.bubble.fill" : "character.bubble").font(.body)
                    .overlay(alignment: .topTrailing) {
                        if model.translationEnabled && !tab.showsHome {
                            if tab.inflight > 0 { ProgressView().controlSize(.mini).offset(x: 12, y: -6) }
                            else if tab.okCount > 0 {
                                Text("\(tab.okCount)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).background(Color.accentColor, in: Capsule()).offset(x: 14, y: -7)
                            }
                        }
                    }
                if !typeSize.isAccessibilitySize { Text(model.translationEnabled ? "翻訳オン" : "翻訳オフ").font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .accessibilityLabel("翻訳（現在\(model.translationEnabled ? "オン" : "オフ")）。\(tab.inflight > 0 ? "翻訳中です。" : (tab.okCount > 0 ? "英語化 \(tab.okCount) 箇所。" : ""))押すと\(model.translationEnabled ? "オフにして全ページを原文に戻します" : "オンにします")")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var tabsButton: some View {
        Button { showTabs = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "square.on.square").font(.body)
                if !typeSize.isAccessibilitySize { Text("タブ \(model.tabs.count)").font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .accessibilityLabel("タブ一覧（\(model.tabs.count) 個）")
    }

    private var moreMenu: some View {
        Menu {
            if let url = tab.currentURL, !tab.showsHome {
                Button { model.openOutside(url) } label: { Label("Safari で開く", systemImage: "safari") }
                if model.bookmarks.isFavorite(url) {
                    Text("お気に入りに登録済み")
                } else {
                    Button { if !model.addFavorite(url: url, title: tab.displayTitle) { addressError = "このページはお気に入りに追加できません（ログイン・個人情報を含みうるページ）" } } label: { Label("お気に入りに追加", systemImage: "star") }
                }
                if !model.decision(for: url).isAllowed, url.host != nil {
                    Button { model.allowTranslation(on: url) } label: { Label("このサイトを翻訳対象に追加", systemImage: "character.bubble") }
                }
            }
            if !tab.showsHome {
                Button { tab.goHomeScreen() } label: { Label("このタブをホームに戻す（ページは閉じます）", systemImage: "house") }
            }
            Button { model.newTab() } label: { Label("新しいタブ（ホーム画面）", systemImage: "plus.square") }
            Button { model.openPaste() } label: { Label("貼り付けて翻訳", systemImage: "doc.on.clipboard") }
            Button { showSettings = true } label: { Label("設定", systemImage: "gearshape") }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "ellipsis.circle").font(.body)
                if !typeSize.isAccessibilitySize { Text("メニュー").font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .accessibilityLabel("その他のメニュー")
    }

    private func barButton(_ symbol: String, _ caption: String, _ a11y: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.body)
                if !typeSize.isAccessibilitySize { Text(caption).font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .disabled(!enabled)
        .accessibilityLabel(a11y)
    }
}

/// Reports the heights of the two bars to the screen that lays the page out around them.
private struct BarHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}
