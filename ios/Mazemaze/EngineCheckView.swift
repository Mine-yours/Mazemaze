import SwiftUI
import MazemazeCore

/// Settings > このアプリについて > エンジンの確認. A maintenance tool: runs 30 fixed sentences through an engine and shows whether
/// the original stays intact, how many phrases come out as English, how long it takes and what it looks like. Nothing is stored or sent.
/// Use it after an iOS update, or to compare Apple Translation with Apple Intelligence. Do not run it while a page is translating.
struct EngineCheckView: View {
    @EnvironmentObject var model: AppModel
    @State private var kind: TranslationEngineKind = .appleTranslation
    @State private var results: [EngineCheckResult] = []
    @State private var running = false
    @State private var progress = (done: 0, total: 0)
    @State private var problem: String?
    @State private var task: Task<Void, Never>?

    private var items: [EngineCheckItem] {
        guard let url = Bundle.main.url(forResource: "engine_check", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return EngineCheck.items(from: data)
    }

    var body: some View {
        Form {
            Section {
                Picker("エンジン", selection: $kind) { ForEach(TranslationEngineKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .disabled(running)
                Button(running ? "確認しています…（\(progress.done)/\(progress.total)）" : "30 文で確認する") { start() }.disabled(running).frame(minHeight: 44)
                if running { Button("やめる", role: .cancel) { task?.cancel() } }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            } footer: {
                Text("決まった 30 文（敬語・口語・慣用句・固有名詞・URL・指示文の混入など）を、選んだエンジンに通します。原文が 1 文字も変わっていないこと、英語にできた句の数、かかった時間、英語の中身を見て、iOS の更新やモデルの変化を確かめます。結果は保存も送信もしません。ページの翻訳中には動かさないでください。")
            }
            if !results.isEmpty {
                let s = EngineCheck.summarize(results)
                Section("まとめ") {
                    Label(s.text, systemImage: s.preservedAll && s.errors == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(s.preservedAll && s.errors == 0 ? Color.green : Color.orange).font(.footnote)
                }
                Section("結果") {
                    ForEach(results) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(r.id)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(r.error != nil ? "エラー" : "\(r.acceptedSpans)/\(r.requestedSpans) 句・\(String(format: "%.1f", r.seconds)) 秒").font(.caption).foregroundStyle(r.error != nil || !r.preserved ? .orange : .secondary)
                            }
                            Text(r.error ?? r.mixed).font(.footnote).lineLimit(4)
                        }
                    }
                }
            }
        }
        .navigationTitle("エンジンの確認")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { kind = model.translationEngine }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        problem = nil; results = []
        let list = items
        guard !list.isEmpty else { problem = "確認用の文が見つかりません。"; return }
        guard let engine = model.deviceEngines.translationEngine(kind) else { problem = "この iPhone では「\(kind.title)」を使えません。"; return }
        running = true; progress = (0, list.count)
        task = Task { @MainActor in
            do {
                results = try await EngineCheck.run(items: list, engine: engine, ratio: 0.5, unit: .phrase) { done, total in
                    Task { @MainActor in progress = (done, total) }
                }
            } catch is CancellationError {
                problem = "途中でやめました。"
            } catch {
                problem = "確認できませんでした。"
            }
            running = false
        }
    }
}
