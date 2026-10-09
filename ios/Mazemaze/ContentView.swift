import SwiftUI
import MazemazeCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            if model.isLoading {
                ProgressView(value: model.progress).progressViewStyle(.linear).accessibilityLabel("読み込み中")
            } else {
                Color.clear.frame(height: 2)
            }
            BrowserView(model: model)
            statusLine
            toolbar
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .onAppear { if model.needsSetup { showSettings = true } }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("検索または URL を入力", text: $model.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    addressFocused = false
                    if let url = AppModel.normalizeAddress(model.addressText) { model.loadURL?(url) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("アドレス欄")
            if model.isLoading {
                Button { model.stopLoading?() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("読み込みを停止")
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if model.inflight > 0 { ProgressView().controlSize(.mini) }
                Text(model.inflight > 0 ? "翻訳中…（順に英語になります）" : model.siteStatus)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer()
                if model.okCount + model.failCount > 0 {
                    Text("置換 \(model.okCount)\(model.failCount > 0 ? "・失敗 \(model.failCount)" : "")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let p = model.lastProblem {
                Text(p).font(.footnote).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
                if model.needsSetup || p.contains("トークン") || p.contains("接続") {
                    Button("設定を開く") { showSettings = true }.font(.footnote)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    private var toolbar: some View {
        HStack {
            barButton("chevron.left", "戻る", "戻る", enabled: model.canGoBack) { model.goBack?() }
            barButton("chevron.right", "進む", "進む", enabled: model.canGoForward) { model.goForward?() }
            barButton("arrow.clockwise", "更新", "更新", enabled: true) { model.reload?() }
            barButton(model.translationEnabled ? "character.bubble.fill" : "character.bubble",
                      model.translationEnabled ? "翻訳オン" : "翻訳オフ",
                      model.translationEnabled ? "翻訳をオフにする（全ページで原文に戻る）" : "翻訳をオンにする", enabled: true) {
                if !model.translationEnabled { model.suspendedForPage = false }
                model.translationEnabled.toggle()
            }
            if model.suspendedForPage {
                barButton("arrow.triangle.2.circlepath", "再翻訳", "このページをもう一度翻訳する", enabled: model.translationEnabled) {
                    model.resumeTranslation()
                }
            } else {
                barButton("arrow.uturn.backward", "原文に戻す", "このページだけ原文に戻す", enabled: model.translationEnabled) {
                    model.restoreOriginal()
                }
            }
            barButton("gearshape", "設定", "設定", enabled: true) { showSettings = true }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
    }

    private func barButton(_ symbol: String, _ caption: String, _ a11y: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.title3)
                Text(caption).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(a11y)
    }
}
