import SwiftUI
import MazemazeCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var token = ""
    @State private var report: ConnectionReport?
    @State private var checking = false
    @State private var newHost = ""
    @State private var hostError: String?
    @State private var saveError: String?
    @State private var ratioDraft = 0.3
    @State private var ratioCommit: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("URL") {
                        TextField("http://（Mac の IP）:8000", text: $serverURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }.accessibilityElement(children: .combine).accessibilityLabel("サーバーの URL")
                    LabeledContent("トークン") {
                        SecureField("Mac に表示された文字列", text: $token)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.accessibilityElement(children: .combine).accessibilityLabel("アクセストークン")
                    Button {
                        Task { await check() }
                    } label: {
                        HStack { Text("保存して接続確認"); if checking { Spacer(); ProgressView() } }
                    }
                    .disabled(checking)
                    if let r = report {
                        Label(r.message, systemImage: r.state == .ok ? "checkmark.circle.fill" : (r.state == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                            .foregroundStyle(r.state == .ok ? .green : (r.state == .warning ? .orange : .red))
                            .font(.footnote)
                    }
                    if let e = saveError { Text(e).font(.footnote).foregroundStyle(.red) }
                } header: { Text("翻訳サーバー（Mac）") } footer: {
                    Text("Mac で ./scripts/run_lan.sh を実行すると、URL とトークンが表示されます（Mac でコピーして、ユニバーサルクリップボードで貼り付けられます）。接続先は Mac / ローカルネットワークのアドレスのみ入力できます。通信は HTTP（暗号化なし）なので、自宅など信頼できる Wi-Fi でだけ使ってください。トークンはこの iPhone のキーチェーンにだけ保存され、閲覧中のページには渡されません。初回の接続時に「ローカルネットワーク」の許可を求められたら許可してください。")
                }

                Section("翻訳") {
                    Toggle("ページの日本語を英語に置き換える", isOn: $model.translationEnabled)
                    VStack(alignment: .leading) {
                        Text("英語化率の目安: \(Int((ratioDraft * 100).rounded()))%")
                        Slider(value: $ratioDraft, in: 0.1...0.7, step: 0.05) { editing in
                            if !editing { model.ratio = ratioDraft }       // apply once, when the finger lifts
                        }
                        .accessibilityLabel("英語化率").accessibilityValue("\(Int((ratioDraft * 100).rounded()))パーセント")
                        .onChange(of: ratioDraft) { _ in
                            // Keyboard / VoiceOver adjustments never report "editing ended": commit after a pause.
                            ratioCommit?.cancel()
                            ratioCommit = Task {
                                try? await Task.sleep(nanoseconds: 700_000_000)
                                if !Task.isCancelled { model.ratio = ratioDraft }
                            }
                        }
                        Text("目標値で、保証ではありません。").font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("置き換える単位", selection: $model.unit) {
                        Text("フレーズ").tag(TranslationUnit.phrase)
                        Text("文").tag(TranslationUnit.sentence)
                    }
                }

                Section {
                    ForEach(model.allowedHosts, id: \.self) { host in Text(host) }
                        .onDelete { idx in model.setAllowedHosts(model.allowedHosts.enumerated().filter { !idx.contains($0.offset) }.map { $0.element }) }
                    HStack {
                        TextField("例: news.example.jp", text: $newHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("追加") { addHost() }.disabled(newHost.isEmpty)
                    }
                    if let e = hostError { Text(e).font(.footnote).foregroundStyle(.red) }
                    Button("初期設定に戻す") { model.setAllowedHosts(SitePolicy.defaultAllowedHosts) }
                } header: { Text("翻訳するサイト") } footer: {
                    Text("ここに登録したサイト（https のみ）だけ、本文を Mac に送って翻訳します。ログイン・DM・設定などのページは対象外です。リンクやボタンの文字は変えません。")
                }

                Section("注意") {
                    Text("Mac との通信は HTTP（暗号化なし）です。自宅など信頼できる Wi-Fi でだけ使ってください。翻訳する文章はこのアプリから Mac のサーバーにだけ送られ、Mac 上の Ollama（ローカルモデル）で処理する設計です。「翻訳オフ」は今後の翻訳を止めて全ページを原文に戻します。「原文に戻す」はそのページだけです。")
                        .font(.footnote)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { save(); dismiss() } } }
            .onAppear {
                serverURL = model.settings.serverURLString
                token = model.settings.token ?? ""
                ratioDraft = model.ratio
            }
            .onDisappear { save() }
        }
    }

    private func save() {
        saveError = nil
        let newURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        if newURL != model.settings.serverURLString { model.settings.serverURLString = newURL; changed = true }
        if newToken != (model.settings.token ?? "") {
            do { try model.settings.setToken(newToken); changed = true } catch { saveError = "トークンをキーチェーンに保存できませんでした" }
        }
        if changed { model.serverSettingsChanged() }      // only then: it resets the page and the cache
    }

    private func check() async {
        checking = true
        save()
        report = await model.checkConnection()
        checking = false
    }

    private func addHost() {
        hostError = nil
        guard let normalized = SitePolicy.normalizeEntry(newHost) else {
            hostError = "このホスト名は登録できません（例: news.example.jp。com や IP アドレスは不可）"
            return
        }
        if !model.allowedHosts.contains(normalized) { model.setAllowedHosts(model.allowedHosts + [normalized]) }
        newHost = ""
    }
}
