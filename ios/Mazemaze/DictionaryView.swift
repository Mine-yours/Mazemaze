import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import MazemazeCore

/// The saved expressions: search, open the source page, add a note, delete, export. Only on this iPhone.
struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [DictionaryEntry] { model.dictionary.search(query) }

    var body: some View {
        NavigationStack {
            List {
                if let p = model.dictionaryProblem { Label(p, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
                if model.dictionary.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("まだ保存したものはありません").font(.headline)
                        Text("ページの英語の部分をタップすると元の日本語が出ます。その吹き出しの「辞書に保存」を押すと、英語と日本語がここに入ります。保存したものはこの iPhone の中だけにあります。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if shown.isEmpty {
                    Text("見つかりません").foregroundStyle(.secondary)
                }
                ForEach(shown) { e in
                    NavigationLink { DictionaryDetailView(id: e.id, closeAll: { dismiss() }) } label: { row(e) }
                }
                .onDelete { offsets in model.removeFromDictionary(ids: Set(offsets.map { shown[$0].id })) }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "英語・日本語・メモで検索")
            .navigationTitle("辞書（\(model.dictionary.entries.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if !model.dictionary.entries.isEmpty {
                        Menu {
                            ShareLink("CSV で書き出す", item: DictionaryCSVExport(data: model.dictionary), preview: SharePreview("辞書（CSV）"))
                            ShareLink("テキストで書き出す", item: DictionaryTextExport(data: model.dictionary), preview: SharePreview("辞書（テキスト）"))
                        } label: { Label("書き出す", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
    }

    private func row(_ e: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(e.english).font(.headline)
                if e.kind == .word { Text("単語").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Color(.tertiarySystemFill), in: Capsule()) }
            }
            meaningLine(e)
            if e.kind == .word, !e.contextEnglish.isEmpty { Text(verbatim: e.contextEnglish).font(.footnote).lineLimit(2) }
            if e.kind == .word, !e.contextJapanese.isEmpty { Text(verbatim: e.contextJapanese).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 6) {
                if !e.source.isEmpty { Text(e.source) }
                Text(e.savedAt, style: .date)
                if !e.note.isEmpty { Image(systemName: "note.text") }
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The meaning of a word, or what is happening to it (looked up in the background), or the Japanese of an expression.
    @ViewBuilder private func meaningLine(_ e: DictionaryEntry) -> some View {
        if e.kind == .word, e.card == nil, e.meaning == .pending {
            if model.foundationModelsProblem != nil {
                Text("Apple Intelligence が使えるようになったら、意味を調べます").font(.subheadline).foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("意味を調べています…").font(.subheadline).foregroundStyle(.secondary) }
            }
        } else if e.kind == .word, e.card == nil, e.meaning == .failed {
            Text("意味を取得できませんでした（項目を開いてやり直せます）").font(.subheadline).foregroundStyle(.orange)
        } else if !e.japanese.isEmpty {
            Text(e.japanese).font(.subheadline).foregroundStyle(.secondary)
            if let h = e.card?.headline, h != e.japanese { Text(h).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

}

/// The CSV is written only when the person actually shares it (never kept around), from the data as it is then.
private struct DictionaryCSVExport: Transferable {
    let data: DictionaryData
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText, exporting: { (item: DictionaryCSVExport) -> SentTransferredFile in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mazemaze-dictionary.csv")
            try ("\u{FEFF}" + item.data.csv()).write(to: url, atomically: true, encoding: .utf8)     // BOM: spreadsheets read UTF-8
            return SentTransferredFile(url)
        })
    }
}

private struct DictionaryTextExport: Transferable {
    let data: DictionaryData
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { (item: DictionaryTextExport) in Data(item.data.plainText().utf8) }
    }
}

private struct DictionaryDetailView: View {
    let id: UUID
    let closeAll: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var back
    @State private var note = ""
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var saveTask: Task<Void, Never>?
    @State private var lookup: LookupSession?
    @Environment(\.scenePhase) private var scenePhase

    private var entry: DictionaryEntry? { model.dictionary.entries.first { $0.id == id } }

    var body: some View {
        Form {
            if let e = entry {
                Section("英語") { Text(e.english).font(.title3).textSelection(.enabled) }
                if e.kind == .word {
                    Section("意味") {
                        if e.card == nil, e.meaning == .pending {
                            if let why = model.foundationModelsProblem {
                                Label("Apple Intelligence が使えないため、まだ調べられません（\(why)）。使えるようになると、自動で調べます", systemImage: "pause.circle").font(.footnote).foregroundStyle(.orange)
                            } else {
                                HStack(spacing: 8) { ProgressView(); Text("調べています（空いたときに、自動で調べます）").foregroundStyle(.secondary) }
                            }
                        } else if e.card == nil, e.meaning == .failed {
                            Label("意味を取得できませんでした", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Button("もう一度、自動で調べる") { model.retryMeaning(entryID: e.id) }.frame(minHeight: 44)
                        } else if !e.japanese.isEmpty { Text(e.japanese).font(.title3).textSelection(.enabled) }
                    }
                    if !e.contextEnglish.isEmpty || !e.contextJapanese.isEmpty {
                        Section("原文") {
                            if !e.contextEnglish.isEmpty { Text(verbatim: e.contextEnglish).textSelection(.enabled) }
                            if !e.contextJapanese.isEmpty { Text(verbatim: e.contextJapanese).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                } else {
                    Section("元の日本語") { Text(e.japanese).font(.title3).textSelection(.enabled) }
                }
                Section {
                    if let card = e.card { CardContent(card: card) }
                    Button(e.card == nil ? "意味を調べる" : "意味を調べ直す") { lookup = model.lookupSession(for: e) }.frame(minHeight: 44)
                } header: { Text(e.card == nil ? "詳しい意味" : "詳しい意味（AI が作成）") } footer: {
                    if e.card == nil { Text("iPhone の Apple Intelligence で、単語の意味や句の解説を調べて、この項目に残します。") }
                }
                Section("出典") {
                    Text(e.source.isEmpty ? "（不明）" : e.source)
                    Text(e.savedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                    if let url = e.sourceURL {
                        Button("元のページを開く") { closeAll(); model.newTab(url: url) }.frame(minHeight: 44)
                    }
                }
                Section("メモ") {
                    TextField("例: 使い方、覚え方", text: $note, axis: .vertical).lineLimit(1...6)
                }
                Section {
                    Button("この項目を削除", role: .destructive) { confirmDelete = true }.frame(minHeight: 44)
                }
            } else {
                Text("この項目は削除されました").foregroundStyle(.secondary)
            }
        }
        .sheet(item: $lookup) { LookupSheet(session: $0).environmentObject(model) }
        .navigationTitle("辞書の項目")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !loaded, let e = entry { note = e.note; loaded = true } }
        .onChange(of: note) { _ in
            saveTask?.cancel()
            saveTask = Task { try? await Task.sleep(nanoseconds: 700_000_000); if !Task.isCancelled { model.setDictionaryNote(id: id, note: note) } }
        }
        .onChange(of: scenePhase) { phase in if phase != .active { saveTask?.cancel(); model.setDictionaryNote(id: id, note: note) } }
        .onDisappear { saveTask?.cancel(); model.setDictionaryNote(id: id, note: note) }
        .confirmationDialog("この項目を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { model.removeFromDictionary(ids: [id]); back() }
            Button("キャンセル", role: .cancel) {}
        }
    }
}
