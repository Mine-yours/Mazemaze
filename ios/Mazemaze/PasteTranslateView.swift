import SwiftUI
import UniformTypeIdentifiers
import MazemazeCore

/// "貼り付けて翻訳": the person copies Japanese text (from Safari, the X app, ...) and pastes it here. The text
/// goes through the same translation as a web page. Nothing is fetched from any site, and nothing is saved.
struct PasteTranslateView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var inputError: String?
    @FocusState private var editing: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if let tab = model.pasteTab { PasteResultView(tab: tab, backToEdit: { model.endPasteResult() }) }
                else { input }
            }
            .navigationTitle("貼り付けて翻訳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { model.closePaste() } } }
            // The app switcher takes a picture of the screen: do not leave the pasted text in it.
            .overlay { if scenePhase != .active { Color(.systemBackground).ignoresSafeArea() } }
        }
    }

    private var count: Int { text.count }

    private var input: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("コピーした日本語の文章（X の投稿、記事の一部など）を貼り付けると、英語混じりにします。英語の部分をタップすると元の日本語が出ます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if model.needsSetup {
                    Label("翻訳サーバー（Mac）が未設定です。ホームの「サーバーを設定する」から QR で設定してください。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                TextEditor(text: $text)
                    .focused($editing)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text("ここに貼り付け").foregroundStyle(.tertiary).padding(.top, 16).padding(.leading, 13).allowsHitTesting(false) }
                    }
                    .accessibilityLabel("翻訳する文章")
                HStack {
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { Task { @MainActor in text = s; inputError = nil } }
                    }
                    .labelStyle(.titleAndIcon).frame(minHeight: 44)
                    Spacer()
                    if !text.isEmpty { Button("消去", role: .destructive) { text = ""; inputError = nil }.frame(minHeight: 44) }
                }
                Text("\(count) / \(PasteSurface.maxCharacters) 文字")
                    .font(.footnote).foregroundStyle(count > PasteSurface.maxCharacters ? Color.red : Color.secondary)
                if let e = inputError { Text(e).font(.footnote).foregroundStyle(.red) }
                Button { submit() } label: { Text("翻訳する").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.needsSetup)
                notes
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("この画面について", systemImage: "info.circle").font(.footnote).bold()
            Group {
                Text("・貼り付けた文章は、Mac 上のローカルモデル（Ollama）だけで処理し、この iPhone のディスクにも保存しません（閉じると画面から消え、アプリを終了するとメモリからも消えます）。ただし、吹き出しの「辞書に保存」を押した表現（最大 300 文字）は、辞書に残ります。")
                Text("・\(model.settings.pinnedFingerprint != nil ? "Mac との通信は暗号化されています。" : "Mac との通信は暗号化されていません（HTTP）。自宅など信頼できる Wi-Fi でだけ使い、他人に見られたくない文章は貼り付けないでください。")")
                Text("・X などのページを自動で読み取ることはしません。コピーは手動です。他人の非公開の投稿や DM は貼り付けないでください。")
                Text("・8 文字に満たない行や、日本語の少ない行は、そのまま残ります。")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func submit() {
        editing = false
        switch PasteSurface.normalize(text) {
        case .failure(let e): inputError = e.message
        case .success(let lines):
            guard PasteSurface.containsJapanese(lines) else {
                inputError = "日本語が見つかりません。日本語の文章を貼り付けてください（英語だけの文章は、そのまま表示されるだけです）。"
                return
            }
            inputError = nil
            model.startPaste(lines: lines)
        }
    }
}

/// The translated text. The page itself is Mazemaze's own template; this view only adds the buttons and the status line.
private struct PasteResultView: View {
    @ObservedObject var tab: TabModel
    let backToEdit: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var copied = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            BrowserView(tab: tab)
            statusLine
            toolbar
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = tab.lastProblem {
                Label(p, systemImage: "exclamationmark.octagon.fill").font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let n = tab.notice {
                Label(n, systemImage: "clock").font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.translationEnabled {
                Button("翻訳がオフです。オンにする") { model.translationEnabled = true }.font(.footnote).frame(minHeight: 44)
            }
            HStack(spacing: 8) {
                if tab.inflight > 0 { ProgressView().controlSize(.small) }
                Text(tab.inflight > 0 ? "翻訳中…（順に英語になります）" : tab.siteStatus).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if tab.okCount > 0 { Text("英語化 \(tab.okCount) 箇所").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var toolbar: some View {
        HStack {
            button("pencil", "文章を直す", "貼り付け画面に戻る（この翻訳結果は消えます）", action: backToEdit)
            if tab.suspendedForPage {
                button("arrow.triangle.2.circlepath", "再翻訳", "もう一度翻訳する", enabled: model.translationEnabled) { tab.resumeTranslation() }
            } else {
                button("arrow.uturn.backward", "原文に戻す", "原文に戻す", enabled: model.translationEnabled) { tab.restoreOriginal() }
            }
            button(copied ? "checkmark" : "doc.on.doc", copied ? "コピー済み" : "コピー", "表示中の文章をコピー") { copy() }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
    }

    private func button(_ symbol: String, _ caption: String, _ a11y: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
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

    /// Copies what is on screen (English parts included). Kept on this device only (no Universal Clipboard).
    private func copy() {
        Task { @MainActor in
            guard let s = await tab.coordinator?.pasteText(), !s.isEmpty else { return }
            UIPasteboard.general.setItems([[UTType.plainText.identifier: s]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
            copied = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}
