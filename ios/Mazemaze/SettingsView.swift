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
    @State private var showToken = false
    @State private var loadedURL = ""          // what the fields showed when the sheet opened: only a real edit counts as a change
    @State private var loadedToken = ""
    @State private var confirmClear = false
    @State private var xIdentity = true
    @State private var autoHideBars = true
    @State private var embedDictionary = true
    @State private var autoMeaning = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("いちばん簡単な方法（QR）").font(.subheadline).bold()
                        Text("Mac で ./scripts/run_lan.sh を実行すると、ターミナルに QR が表示されます。iPhone の標準「カメラ」アプリで読み取り、出てきた通知をタップして、確認画面で「ペアリングする」を押すだけです。QR は画面から直接読み取るので、Wi-Fi 上でトークンが漏れません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    PasteButton(payloadType: String.self) { strings in
                        if let text = strings.first { Task { @MainActor in model.receivePairing(text) } }
                    }
                    .labelStyle(.titleAndIcon).frame(minHeight: 44)
                    Text("Mac に表示された「mazemaze://pair?…」の 1 行をコピーしてから、上のボタンを押します（iPhone が貼り付けの許可を聞くことがあります）。").font(.caption).foregroundStyle(.secondary)
                    if let name = pairedSummary { Label(name, systemImage: model.settings.pinnedFingerprint != nil ? "lock.fill" : "lock.open").font(.footnote).foregroundStyle(model.settings.pinnedFingerprint != nil ? Color.green : Color.orange) }
                } header: { Text("ペアリング") }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("手入力する場合（暗号化なしの HTTP のみ）").font(.subheadline).bold()
                        Text("手入力では、暗号化（証明書の確認）は使えません。できるだけ上の QR か貼り付けを使ってください。手入力するときは、Mac を MAZEMAZE_TLS=0 ./scripts/run_lan.sh で起動し、表示された http:// の URL とトークンを入力して「保存して接続確認」を押します（ローカルネットワークの許可が出たら「許可」し、もう一度押します）。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("URL") {
                        TextField("例: http://192.168.0.19:8000", text: $serverURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityLabel("サーバーの URL")
                    }
                    LabeledContent("トークン") {
                        HStack {
                            Group {
                                if showToken { TextField("Mac に表示された文字列", text: $token) } else { SecureField("Mac に表示された文字列", text: $token) }
                            }
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("アクセストークン")
                            Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless).accessibilityLabel(showToken ? "トークンを隠す" : "トークンを表示")
                        }
                    }
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
                    Text("接続先は Mac / ローカルネットワークのアドレスのみ入力できます。トークンはこの iPhone のキーチェーンにだけ保存され、閲覧中のページには渡されません。初回の接続時に「ローカルネットワーク」の許可を求められたら許可してください。\(model.settings.pinnedFingerprint != nil ? "いまの接続は暗号化されています。" : "いまの接続は暗号化されていません（HTTP）。自宅など信頼できる Wi-Fi でだけ使ってください。")")
                }

                Section {
                    Toggle("スクロールでバーを隠す", isOn: $autoHideBars)
                        .onChange(of: autoHideBars) { v in model.settings.autoHideBars = v; model.settings.flush(); if !v { model.active.revealBars() } }
                } header: { Text("表示") } footer: {
                    Text("ページを下にスクロールすると、アドレス欄とツールバーが隠れて、画面を広く使えます。上にスクロールするか、下の「メニューを表示」を押すと戻ります。VoiceOver 使用中は隠しません。")
                }

                Section {
                    Toggle("標準辞書をシートの中に表示", isOn: $embedDictionary)
                        .onChange(of: embedDictionary) { v in model.settings.embedDictionary = v; model.settings.flush() }
                } footer: {
                    Text(model.settings.embedDictionaryCrashed
                         ? "単語の意味のシートで標準辞書を表示しているときにアプリが落ちたため、自動でオフにしました。オンに戻すと、もう一度試します（また落ちたら、再びオフになります）。オフの間は、ボタンを押すと別のシートで開きます。"
                         : "単語の意味のシートの中に、iPhone の標準辞書の内容を直接表示します。オフにすると、ボタンを押したときに別のシートで開きます。")
                }

                Section {
                    Toggle("保存した単語の意味を、裏で自動で調べる", isOn: $autoMeaning)
                        .onChange(of: autoMeaning) { v in model.settings.autoMeaning = v; model.settings.flush(); if v { model.startMeaningWorker() } }
                } footer: {
                    Text("標準辞書から単語を保存すると、Mac のローカルモデルが、その文での意味を調べて項目に入れます。翻訳を優先するため、しばらく翻訳がない間に、1 件ずつ調べます。Mac が止まっているときは、あとで自動でやり直します。")
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
                            guard abs(ratioDraft - model.ratio) > 0.0001 else { return }
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
                        Button("追加") { addHost() }.disabled(newHost.isEmpty).buttonStyle(.borderless)
                    }
                    if let e = hostError { Text(e).font(.footnote).foregroundStyle(.red) }
                    Button("初期設定に戻す") { model.setAllowedHosts(SitePolicy.defaultAllowedHosts) }
                    Toggle("X を Safari として開く", isOn: $xIdentity)
                        .onChange(of: xIdentity) { v in model.settings.safariIdentityForX = v; model.settings.flush() }
                } header: { Text("翻訳するサイト") } footer: {
                    Text("ここに登録したサイト（https のみ）だけ、本文を Mac に送って翻訳します。ログイン・DM・設定などのページは対象外です。リンクやボタンの文字は変えません。\n「X を Safari として開く」: X は、アプリ内ブラウザを Safari に誘導します。オンの間は、x.com / twitter.com に限り、Safari と同じ形式の UA を送り、Safari が持つ 2 つの目印（SchemaDataExtractor / MicrodataExtractor）を空の値で用意します。他のサイトには何もしません。オフにすると X は Safari へ誘導されます。変更は新しいタブから有効です。")
                }

                Section {
                    Toggle("起動時に前回のタブを開く", isOn: $model.restoreTabsEnabled)
                    Toggle("最近開いたサイトを記録する", isOn: $model.recentsEnabled)
                    Button("履歴を消去（最近のサイトと保存したタブ）", role: .destructive) { confirmClear = true }
                        .confirmationDialog("最近開いたサイトと、保存されたタブの情報を消去しますか？（いま開いているタブは、次に操作したときに再び保存されます。ログイン情報や Cookie は消えません）", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("履歴を消去", role: .destructive) { model.clearHistory() }
                            Button("キャンセル", role: .cancel) {}
                        }
                } header: { Text("タブと履歴") } footer: {
                    Text("保存されるのは、ログイン・メール・ネットバンキング等を除く公開ページの URL（検索条件や認証情報は含みません）と、翻訳対象サイトのページ題名だけです。どちらもこの iPhone の中だけで、iCloud などのバックアップに含まれることがあります。ログイン情報や Cookie は「履歴を消去」では消えません。")
                }

                Section("注意") {
                    Text("\(model.settings.pinnedFingerprint != nil ? "Mac との通信は暗号化されています（ペアリングした証明書と同じ Mac にだけ接続します）。" : "Mac との通信は HTTP（暗号化なし）です。自宅など信頼できる Wi-Fi でだけ使ってください。")翻訳する文章はこのアプリから Mac のサーバーにだけ送られ、Mac 上の Ollama（ローカルモデル）で処理する設計です。「翻訳オフ」は今後の翻訳を止めて全ページを原文に戻します。「原文に戻す」はそのページだけです。")
                        .font(.footnote)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { save(); dismiss() } } }
            .onAppear {
                serverURL = model.settings.serverURLString
                token = model.settings.token ?? ""
                loadedURL = serverURL; loadedToken = token
                ratioDraft = model.ratio
                xIdentity = model.settings.safariIdentityForX
                autoHideBars = model.settings.autoHideBars
                embedDictionary = model.settings.embedDictionary
                autoMeaning = model.settings.autoMeaning
            }
            .onDisappear { ratioCommit?.cancel(); if abs(ratioDraft - model.ratio) > 0.0001 { model.ratio = ratioDraft }; save() }
        }
    }

    private var pairedSummary: String? {
        guard let cfg = model.settings.serverConfig() else { return nil }
        let name = model.settings.serverName.isEmpty ? (cfg.baseURL.host ?? "Mac") : model.settings.serverName
        return cfg.pinnedFingerprint != nil ? "\(name) とペアリング済み（暗号化あり・証明書で確認）" : "\(name) に接続設定済み（暗号化なし・HTTP）"
    }

    private func save() {
        saveError = nil
        // Only what the person typed counts. If a pairing was applied while this sheet was open, the
        // fields still show the old values and must not overwrite it.
        guard serverURL != loadedURL || token != loadedToken else { return }
        let newURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        if newURL != loadedURL {
            // A half-typed or invalid address must not wipe a working pairing.
            guard newURL.isEmpty || { if case .success = LocalHostPolicy.validate(newURL) { return true } else { return false } }() else {
                saveError = "このアドレスは保存できません。Mac / ローカルネットワークの http(s):// のアドレス（例: http://192.168.0.19:8000）を入力してください。"
                return
            }
            if newURL != model.settings.serverURLString {          // typed by hand: the paired certificate / fallback no longer apply
                model.settings.pinnedFingerprint = nil
                model.settings.fallbackURLString = ""
                model.settings.tailscaleURLString = ""
                model.settings.serverName = ""
                model.settings.serverURLString = newURL
                changed = true
            }
            loadedURL = serverURL
        }
        if newToken != loadedToken {
            if newToken != (model.settings.token ?? "") {
                do { try model.settings.setToken(newToken); changed = true; loadedToken = token }
                catch { saveError = "トークンをキーチェーンに保存できませんでした（もう一度「保存して接続確認」を押してください）" }
            } else { loadedToken = token }
        }
        if changed { model.settings.flush(); model.serverSettingsChanged() }      // only then: it resets the page and the cache
    }

    private func check() async {
        checking = true
        save()
        report = await model.checkConnection()
        checking = false
        if report?.state == .ok { model.active.recoverIfNeeded(); model.warmupIfNeeded() }
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
