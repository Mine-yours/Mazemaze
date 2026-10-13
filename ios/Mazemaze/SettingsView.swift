import SwiftUI
import MazemazeCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newHost = ""
    @State private var hostError: String?
    @State private var ratioDraft = 0.3
    @State private var ratioCommit: Task<Void, Never>?
    @State private var confirmClear = false
    @State private var xIdentity = true
    @State private var autoHideBars = true
    @State private var embedDictionary = true
    @State private var autoMeaning = true
    @State private var searchEngine: SearchEngine = .google

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("標準辞書から単語を保存すると、iPhone の Apple Intelligence が、その文での意味を調べて項目に入れます。翻訳を優先するため、しばらく翻訳がない間に、1 件ずつ調べます。使えないときは、あとで自動でやり直します。")
                }

                Section {
                    Picker("ページの翻訳", selection: $model.translationEngine) {
                        ForEach(TranslationEngineKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(model.translationEngine.hint).font(.footnote).foregroundStyle(.secondary)
                    if model.translationEngine == .appleTranslation {
                        Label("Apple 翻訳: \(model.appleTranslationStatus)", systemImage: model.appleTranslationInstalled ? "checkmark.circle" : "arrow.down.circle")
                            .font(.footnote).foregroundStyle(model.appleTranslationInstalled ? Color.green : Color.orange)
                        if model.appleTranslationCanDownload {
                            Button("翻訳データをダウンロード（システムの確認が出ます）") { model.requestAppleTranslationDownload() }.frame(minHeight: 44)
                        }
                    }
                    LabeledContent("単語・句の意味") { Text("Apple Intelligence") }
                    Text("単語をタップしたときの「この文での意味（AI）」と、保存した単語の意味の自動検索を作ります。標準辞書は別で、いつでも使えます。").font(.footnote).foregroundStyle(.secondary)
                    if let problem = model.foundationModelsProblem {
                        Label("Apple Intelligence: \(problem)", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    } else {
                        Label("Apple Intelligence: 使えます", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
                    }
                } header: { Text("翻訳と意味の作り方") } footer: {
                    Text("どちらも iPhone の中だけで処理し、文章は通信しません（Apple 翻訳のデータをダウンロードするときだけ通信します）。置き換える場所の選び方・原文の保持・検査は、どちらを選んでも同じです。")
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
                    Text("ここに登録したサイト（https のみ）だけ、本文を翻訳します（iPhone の中で処理します）。ログイン・DM・設定などのページは対象外です。リンクやボタンの文字は変えません。\n「X を Safari として開く」: X は、アプリ内ブラウザを Safari に誘導します。オンの間は、x.com / twitter.com に限り、Safari と同じ形式の UA を送り、Safari が持つ 2 つの目印（SchemaDataExtractor / MicrodataExtractor）を空の値で用意します。他のサイトには何もしません。オフにすると X は Safari へ誘導されます。変更は新しいタブから有効です。")
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

                Section {
                    Picker("検索エンジン", selection: $searchEngine) {
                        ForEach(SearchEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .onChange(of: searchEngine) { v in model.settings.searchEngine = v; model.settings.flush() }
                } header: { Text("検索") } footer: {
                    Text("アドレス欄に入れた語句（URL ではないもの）は、選んだ検索サービスに送られ、検索結果のページが開きます。ページの本文は送られません。")
                }

                Section {
                    NavigationLink {
                        BackupView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("バックアップと復元")
                            Text("辞書 \(model.dictionary.entries.count) 件・" + (model.settings.lastBackupExport.map { "最後に書き出した日 " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "まだ書き出していません"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(minHeight: 44)
                } header: { Text("データ") } footer: {
                    Text("辞書とお気に入りは、この iPhone の中にだけあります（アプリが外に送ることはありません。iPhone 全体のバックアップには含まれます）。アプリを削除すると消えるので、ときどき書き出してください。")
                }

                Section {
                    LabeledContent("バージョン") { Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")）") }
                    LabeledContent("署名の期限") {
                        if let d = model.signatureExpiry, let left = model.signatureDaysLeft {
                            Text("\(d.formatted(date: .abbreviated, time: .omitted))（あと \(left) 日）").foregroundStyle(left <= 2 ? Color.orange : Color.primary)
                        } else { Text("確認できません").foregroundStyle(.secondary) }
                    }
                    NavigationLink("エンジンの確認（保守用）") { EngineCheckView() }.frame(minHeight: 44)
                } header: { Text("このアプリについて") } footer: {
                    Text("無料の Apple ID で入れたアプリは、入れてから 7 日で署名が切れて、起動できなくなります。切れたら、Mac の Xcode からもう一度入れ直してください（アプリは削除しないでください。データが消えます）。")
                }

                Section("注意") {
                    Text("翻訳する文章は、この iPhone の中だけで処理され、外部のサーバーには送られません。「翻訳オフ」は今後の翻訳を止めて全ページを原文に戻します。「原文に戻す」はそのページだけです。")
                        .font(.footnote)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .onAppear {
                ratioDraft = model.ratio
                xIdentity = model.settings.safariIdentityForX
                autoHideBars = model.settings.autoHideBars
                embedDictionary = model.settings.embedDictionary
                autoMeaning = model.settings.autoMeaning
                searchEngine = model.settings.searchEngine
                model.refreshEngineStatus()
            }
            .onDisappear { ratioCommit?.cancel(); if abs(ratioDraft - model.ratio) > 0.0001 { model.ratio = ratioDraft } }
        }
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
