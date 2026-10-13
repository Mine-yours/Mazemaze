import SwiftUI
import UniformTypeIdentifiers
import MazemazeCore

/// Backup and restore (Settings > データ). The backup is a plain file the person writes where they want it; nothing is synced or sent.
struct BackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var exporting = false
    @State private var exportData = Data()            // made when the button is pressed, not on every redraw
    @State private var importing = false
    @State private var pendingImport: BackupFile?
    @State private var restoreTarget: DictionarySnapshots.Snapshot?
    @State private var deleteTarget: URL?
    @State private var message: String?
    @State private var snaps: [DictionarySnapshots.Snapshot] = []
    @State private var aside: [URL] = []

    private var lastExport: Date? { model.settings.lastBackupExport }
    private var needsReminder: Bool {
        guard !model.dictionary.entries.isEmpty else { return false }
        guard let last = lastExport else { return true }
        return Date().timeIntervalSince(last) > 30 * 86_400
    }

    /// Sites the file would add to the translation list (shown before the person agrees).
    private func newHosts(in f: BackupFile) -> [String] {
        f.allowedHosts.prefix(Backup.maxHosts).compactMap(Backup.importableHost).filter { !model.allowedHosts.contains($0) }
    }

    /// A message right after a dialog closes can be dropped by SwiftUI: show it a moment later.
    private func say(_ text: String) {
        Task { @MainActor in try? await Task.sleep(nanoseconds: 450_000_000); message = text }
    }

    private func reload() {
        aside = model.dictionaryStorage.asideFiles()
        let snapshots = model.snapshots
        Task { snaps = await Task.detached { snapshots.list() }.value }          // reading the copies off the main thread
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("辞書") { Text("\(model.dictionary.entries.count) 件") }
                LabeledContent("お気に入り") { Text("\(model.bookmarks.favorites.count) 件") }
                LabeledContent("翻訳するサイト") { Text("\(model.allowedHosts.count) 件") }
                LabeledContent("最後に書き出した日") { if let d = lastExport { Text(d, style: .date) } else { Text("まだありません") } }
                if needsReminder {
                    Label("書き出しておくと安心です。アプリを削除したり、署名が切れて入れ直したりするときに、データを守れます。", systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: { Text("いまのデータ") }

            Section {
                Button {
                    guard let data = model.makeBackupData() else { message = "バックアップを作れませんでした。"; return }
                    exportData = data; exporting = true
                } label: { Label("バックアップを書き出す", systemImage: "square.and.arrow.up") }.frame(minHeight: 44)
                Button { importing = true } label: { Label("バックアップを取り込む", systemImage: "square.and.arrow.down") }.frame(minHeight: 44)
            } header: { Text("バックアップ") } footer: {
                Text("辞書（意味カード・読んだ文を含む）、お気に入り、翻訳するサイトを 1 つのファイルに書き出します。保存先は、ファイルアプリ（iCloud Drive を含む）などから、あなたが選びます。アプリが自動で送ったり、同期したりはしません。取り込みは「統合」で、いまあるものは消さず（お気に入りは、空きの分だけ追加します）、同じものは追加しません。")
            }

            Section {
                if snaps.isEmpty {
                    Text("まだ控えがありません（辞書に何か保存した次の日から、できます）。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(snaps) { s in
                    Button { restoreTarget = s } label: {
                        HStack {
                            Text(s.date, format: .dateTime.year().month().day().hour().minute())
                            if s.isBeforeCopy { Text("（取り込み・復元の前）").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(s.entryCount >= 0 ? "\(s.entryCount) 件" : "読めません").foregroundStyle(s.entryCount >= 0 ? Color.secondary : Color.orange)
                        }
                    }.frame(minHeight: 44)
                }
            } header: { Text("前の状態に戻す") } footer: {
                Text("毎日、最初に起動したときに、辞書の控えをアプリの中に残します（毎日の分は 8 つ、取り込み・復元の前の分は 3 つまで）。選ぶと、その時点の辞書に戻します（戻す前の辞書も控えに残します）。アプリを削除すると、この控えも消えます。")
            }

            if !aside.isEmpty {
                Section {
                    ForEach(aside, id: \.self) { url in
                        HStack {
                            ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "doc") }.font(.footnote)
                            Spacer()
                            Button(role: .destructive) { deleteTarget = url } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                .accessibilityLabel("このファイルを削除")
                        }
                    }
                } header: { Text("読み込めなかった辞書のファイル") } footer: {
                    Text("辞書のファイルが壊れていたとき、元のファイルをここに残してあります。共有（ファイルへ保存など）で取り出せます。消すと、元に戻せません。")
                }
            }
        }
        .navigationTitle("バックアップと復元")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .fileExporter(isPresented: $exporting, document: BackupDocument(data: exportData), contentType: .json, defaultFilename: model.backupFileName) { result in
            switch result {
            case .success: model.markBackupExported(); say("書き出しました。")
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { say("書き出せませんでした。") }          // cancelling is not a failure
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // The size must be known and small before anything is read.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= BackupFile.maxBytes else { say(BackupError.tooLarge.message); return }
            guard let data = try? Data(contentsOf: url) else { say(BackupError.unreadable.message); return }
            Task {
                let checked = await Task.detached { Backup.decodeResult(data) }.value            // a large file is parsed off the main thread
                switch checked {
                case .success(let file): pendingImport = file
                case .failure(let e): say(e.message)
                }
            }
        }
        .alert("このバックアップを取り込みますか？", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button("取り込む") {
                if let f = pendingImport {
                    switch model.importBackup(f) {
                    case .imported(let r): say("取り込みました。\n" + r.summary)
                    case .failed(let why): say("取り込めませんでした（何も変えていません）。\n" + why)
                    }
                    reload()
                }
                pendingImport = nil
            }
            Button("キャンセル", role: .cancel) { pendingImport = nil }
        } message: {
            if let f = pendingImport {
                let hosts = newHosts(in: f)
                Text("作成: \(f.createdAt.formatted(date: .abbreviated, time: .shortened))\n辞書 \(f.dictionary.entries.count) 件・お気に入り \(f.favorites.count) 件\nいまあるものは消さず、同じものは追加しません。"
                     + (hosts.isEmpty ? "" : "\n翻訳するサイトに追加: " + hosts.prefix(8).joined(separator: "、") + (hosts.count > 8 ? " ほか \(hosts.count - 8) 件" : "")))
            }
        }
        .confirmationDialog("この時点の辞書に戻しますか？", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }), titleVisibility: .visible) {
            Button("戻す", role: .destructive) {
                if let s = restoreTarget {
                    switch model.restoreSnapshot(s) {
                    case .restored(let n): say("戻しました（辞書 \(n) 件）。戻す前の辞書は、控えに残してあります。")
                    case .refusedBecauseUnwritable: say("いまの辞書のファイルを読めないため、戻しませんでした（元のファイルを守るためです）。")
                    case .unreadableCopy: say("この控えは、読めないか、新しい版のアプリのものなので、戻せません。")
                    case .couldNotKeepCurrent: say("いまの辞書の控えを作れなかったため、戻しませんでした。空き容量を確認してください。")
                    case .couldNotWrite: say("戻せませんでした（保存できません）。")
                    }
                    reload()
                }
                restoreTarget = nil
            }
            Button("キャンセル", role: .cancel) { restoreTarget = nil }
        } message: {
            if let s = restoreTarget { Text("\(s.date.formatted(date: .abbreviated, time: .shortened)) の辞書（\(s.entryCount >= 0 ? "\(s.entryCount) 件" : "件数は不明")）に戻します。いまの辞書も、控えに残します。") }
        }
        .confirmationDialog("このファイルを削除しますか？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("削除する", role: .destructive) { if let u = deleteTarget { model.removeAsideFile(u); reload() }; deleteTarget = nil }
            Button("キャンセル", role: .cancel) { deleteTarget = nil }
        } message: { Text("読み込めなかった辞書の元のファイルです。削除すると、元に戻せません。先に共有で取り出すこともできます。") }
        .alert("バックアップ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}
