import SwiftUI
import MazemazeCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var showTabs = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        PageScreen(tab: model.active, showSettings: $showSettings, showTabs: $showTabs)
            .id(model.activeID)
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
            .sheet(isPresented: $showTabs) { TabSwitcherView().environmentObject(model) }
            .onAppear {
                #if DEBUG
                // Screenshots only (simulator): open a sheet or a pairing prompt from a launch argument.
                switch SelfTest.value("-MazemazeShow") {
                case "tabs"?: showTabs = true; return
                case "settings"?: showSettings = true; return
                case "pairing"?: if let p = SelfTest.value("-MazemazePairGood") { model.receivePairing(p) }; return
                default: break
                }
                #endif
                if model.needsSetup { showSettings = true } else { model.warmupIfNeeded() }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.active.recoverIfNeeded(); model.warmupIfNeeded() }
                if phase == .background { model.persistTabsNow() }          // the 0.8 s delayed save may not get to run
            }
            .onChange(of: model.pairingNonce) { _ in
                // An alert cannot appear above an open sheet: close them, let the animation finish, then ask.
                showSettings = false; showTabs = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    model.pairingPromptVisible = true
                }
            }
            .alert(model.pendingPairing?.isEncrypted == false ? "暗号化なしでペアリングしますか？" : "このMacとペアリングしますか？",
                   isPresented: Binding(get: { model.pairingPromptVisible && model.pendingPairing != nil }, set: { if !$0 && model.pendingPairing != nil { model.cancelPairing() } })) {
                Button("ペアリングする") { model.confirmPairing() }
                Button("キャンセル", role: .cancel) { model.cancelPairing() }
            } message: { Text(pairingSummary(model.pendingPairing, downgrade: model.settings.pinnedFingerprint != nil && model.pendingPairing?.isEncrypted == false)) }
            .alert("ペアリング", isPresented: Binding(get: { (model.pairingPromptVisible && model.pairingError != nil) || model.pairingResult != nil }, set: { if !$0 { model.pairingError = nil; model.pairingResult = nil; model.pairingPromptVisible = false } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.pairingError ?? model.pairingResult ?? "") }
            .alert("タブ", isPresented: Binding(get: { model.tabNotice != nil }, set: { if !$0 { model.tabNotice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.tabNotice ?? "") }
    }
}

/// What the person is asked to confirm before a pairing is applied: where, and whether it is encrypted.
func pairingSummary(_ p: PairingPayload?, downgrade: Bool = false) -> String {
    guard let p else { return "" }
    var lines = ["Mac: \(p.name ?? p.host ?? p.ip ?? "?")", "アドレス: \(p.primaryURL.absoluteString)"]
    if let f = p.fallbackURL { lines.append("予備のアドレス: \(f.absoluteString)") }
    if p.isEncrypted {
        lines.append("通信: 暗号化あり。証明書の指紋 \(p.shortFingerprint ?? "") と同じ証明書を持つ Mac にだけ接続し、違う機器には接続しません（Mac の画面に出ている指紋の先頭と比べられます）。")
    } else {
        lines.append("通信: 暗号化なし（HTTP）。同じ Wi-Fi の人に、翻訳する文章とトークンを見られる可能性があります。")
    }
    if downgrade { lines.append("注意: いまは暗号化ありで接続していますが、暗号化なしに切り替わります。") }
    lines.append("いまの接続設定は置き換わります。心当たりのない QR は使わないでください。")
    return lines.joined(separator: "\n")
}

/// One tab on screen: address bar, page (or the home screen), status line and the toolbar.
struct PageScreen: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @Binding var showTabs: Bool
    @FocusState private var addressFocused: Bool
    @State private var pendingSearch: String?
    @State private var showProblemDetail = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var addressError: String?

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            if tab.isLoading {
                ProgressView(value: tab.progress).progressViewStyle(.linear).accessibilityLabel("読み込み中")
            } else {
                Color.clear.frame(height: 2)
            }
            ZStack {
                if tab.showsHome {
                    HomeView(tab: tab, showSettings: $showSettings)
                } else {
                    BrowserView(tab: tab)
                    if let blocked = tab.blockedNavigation { blockedCard(blocked) }
                }
            }
            statusLine
            toolbar
        }
        .alert("エラーの内容", isPresented: $showProblemDetail) { Button("OK", role: .cancel) {} } message: { Text(tab.lastProblem ?? "") }
        .confirmationDialog(searchDialogTitle, isPresented: Binding(get: { pendingSearch != nil }, set: { if !$0 { pendingSearch = nil } }), titleVisibility: .visible) {
            Button("\(AddressInput.searchServiceName) で検索する") {
                if let words = pendingSearch, let url = AddressInput.searchURL(for: words) { tab.navigate(to: url) }
                pendingSearch = nil
            }
            Button("キャンセル", role: .cancel) { pendingSearch = nil }
        } message: {
            Text("入力した語句が、外部の検索サービス（\(AddressInput.searchServiceName)）に送られます。ページ本文の翻訳とは別の通信です。")
        }
    }

    private var searchDialogTitle: String { "「\((pendingSearch ?? "").prefix(30))」を検索" }

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
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("アドレス欄（URL または検索語）")
                    .overlay(alignment: .trailing) {
                        if addressFocused && !tab.addressText.isEmpty {
                            Button { tab.addressText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                                .accessibilityLabel("入力を消す")
                        }
                    }
                if tab.isLoading {
                    Button { tab.stopLoading?() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("読み込みを停止")
                } else if !tab.showsHome {
                    Button { tab.reload?() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel("更新")
                }
            }
            if let e = addressError { Text(e).font(.footnote).foregroundStyle(Color.red) }
        }
        .padding(.horizontal, 10).padding(.top, 6)
    }

    private func submitAddress() {
        addressFocused = false
        addressError = nil
        switch AddressInput.classify(tab.addressText) {
        case .url(let url): tab.navigate(to: url)
        case .search(let words): pendingSearch = words          // asks first: the words leave this device
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
                     ? "\(b.host) は、アプリ内ブラウザからのアクセスを Safari に誘導しています。Mazemaze はこの制限を回避しません。Safari で開くことはできますが、翻訳はされません。"
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

    // MARK: status line
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !tab.showsHome {
                HStack(spacing: 6) {
                    if tab.inflight > 0 { ProgressView().controlSize(.mini) }
                    Text(statusText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                    if tab.okCount + tab.failCount > 0 {
                        Text("英語化 \(tab.okCount) 箇所\(tab.failCount > 0 ? "・失敗 \(tab.failCount)" : "")")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
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
        .padding(.horizontal, 12).padding(.vertical, tab.showsHome && tab.notice == nil && tab.lastProblem == nil ? 0 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    private var statusText: String {
        if tab.inflight > 0 {
            return tab.okCount == 0 ? "翻訳中…（最初は 1 分ほどかかることがあります。順に英語になります）" : "翻訳中…（順に英語になります）"
        }
        return tab.siteStatus
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
            barButton(model.translationEnabled ? "character.bubble.fill" : "character.bubble",
                      model.translationEnabled ? "翻訳オン" : "翻訳オフ",
                      "翻訳（現在\(model.translationEnabled ? "オン" : "オフ")）。押すと\(model.translationEnabled ? "オフにして全ページを原文に戻します" : "オンにします")", enabled: true) {
                if !model.translationEnabled { tab.suspendedForPage = false }
                model.translationEnabled.toggle()
            }
            if tab.suspendedForPage {
                barButton("arrow.triangle.2.circlepath", "再翻訳", "このページをもう一度翻訳する", enabled: model.translationEnabled) { tab.resumeTranslation() }
            } else {
                barButton("arrow.uturn.backward", "原文に戻す", "このページだけ原文に戻す", enabled: model.translationEnabled && !tab.showsHome) { tab.restoreOriginal() }
            }
            moreMenu
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
    }

    private var tabsButton: some View {
        Button { showTabs = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "square.on.square").font(.title3)
                if !typeSize.isAccessibilitySize { Text("タブ \(model.tabs.count)").font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
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
            Button { showSettings = true } label: { Label("設定", systemImage: "gearshape") }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "ellipsis.circle").font(.title3)
                if !typeSize.isAccessibilitySize { Text("メニュー").font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("その他のメニュー")
    }

    private func barButton(_ symbol: String, _ caption: String, _ a11y: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.title3)
                if !typeSize.isAccessibilitySize { Text(caption).font(.caption2).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(a11y)
    }
}
