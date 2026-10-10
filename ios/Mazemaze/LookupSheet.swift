import SwiftUI
import AVFoundation
import UIKit
import MazemazeCore

/// Where a lookup came from, and what saving it should do.
struct LookupSession: Identifiable, Equatable {
    /// What the sheet shows first. A word starts with the iPhone's own dictionary (instant, offline); the Mac's model
    /// ("この文での意味") only runs when asked for. A phrase has no dictionary, so it starts with the model's answer.
    enum Mode: Equatable { case dictionary, ai }

    let id = UUID()
    var request: LookupRequest
    let source: String            // host, or "貼り付け"
    let sourceURL: URL?
    let existingEntry: UUID?      // opened from a saved dictionary entry: the card is attached to it
    var mode: Mode { request.kind == .word && existingEntry == nil ? .dictionary : .ai }
}

/// The half-height sheet with the meaning of a word (in the sentence it was read in) or of the whole phrase.
/// The card is made by the local model on the Mac and is shown as AI-made.
struct LookupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var request: LookupRequest
    @State private var state: LoadState = .loading
    @State private var saved: SaveState = .none
    @State private var more: MoreState = .idle
    @State private var mode: LookupSession.Mode
    @State private var showSystemDictionary = false
    @State private var detent: PresentationDetent = .large
    @ObservedObject private var speaker = Speaker.shared
    @Environment(\.scenePhase) private var scenePhase
    let session: LookupSession

    enum LoadState: Equatable { case loading, loaded(DefinitionCard), failed(TranslationFailure) }
    enum SaveState: Equatable { case none, saved, duplicate, failed(String) }
    enum MoreState: Equatable { case idle, loading, failed(TranslationFailure) }

    init(session: LookupSession) {
        self.session = session
        _request = State(initialValue: session.request)
        // Nothing here may touch the system dictionary: this runs every time SwiftUI rebuilds the sheet, and UIKit's
        // dictionary lookup crashed on the phone when it was driven from the layout pass.
        _mode = State(initialValue: session.mode)
    }

    private var showsDictionary: Bool { request.kind == .word && mode == .dictionary }

    /// Whether the dictionary is shown inside this sheet (it can be switched off, and does so by itself after a crash).
    private var embedsDictionary: Bool { model.settings.embedDictionary }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if choices.count > 1 { chips }
                    if request.kind == .word { modePicker }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
                if showsDictionary {
                    if embedsDictionary {
                        // The iPhone's dictionary right here, under the word, the sentence and the word choices.
                        InlineDictionaryView(term: request.term, marker: model.dictionaryEmbedMarker).frame(maxHeight: .infinity)
                    } else { dictionaryPane }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            content
                            Label(aiNotice, systemImage: "info.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(request.kind == .word ? "単語" : "句の意味")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // When the dictionary is not shown inside the sheet, it opens in its own sheet, only when asked for.
        .sheet(isPresented: $showSystemDictionary) { SystemDictionaryView(term: request.term).ignoresSafeArea() }
        // A pasted text must not stay in the app switcher's picture of the screen.
        .overlay { if scenePhase != .active && session.source == DictionaryData.pasteSource { Color(.systemBackground).ignoresSafeArea() } }
        #if DEBUG
        .task { if SelfTest.value("-MazemazeOpenDictionary") == "1" { try? await Task.sleep(nanoseconds: 3_000_000_000); showSystemDictionary = true } }      // screenshots
        #endif
        // The Mac is only asked when the model's answer is what is on screen.
        .task(id: "\(request.id)|\(showsDictionary)") {
            if showsDictionary { detent = embedsDictionary ? .large : .medium } else { detent = .medium; await load() }
        }
    }

    /// The word, the sentence it was read in (above), and one tap to the iPhone's dictionary. No network, no Mac.
    private var dictionaryPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.settings.embedDictionaryCrashed {
                Label("標準辞書をシートの中に表示しようとしたときにアプリが落ちたため、自動でオフにしました（設定でもう一度オンにできます）。", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button { showSystemDictionary = true } label: {
                Label("標準辞書で「\(request.term)」を開く", systemImage: "character.book.closed").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            Text("上の日本語の原文を手がかりに、辞書の意味から選んでください。辞書が出ないときは、設定 > 一般 > 辞書 で英和辞書をダウンロードするか、上の「この文での意味（AI）」に切り替えてください。")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var modePicker: some View {
        Picker("表示", selection: $mode) {
            Text("標準辞書").tag(LookupSession.Mode.dictionary)
            Text("この文での意味（AI）").tag(LookupSession.Mode.ai)
        }
        .pickerStyle(.segmented)
    }

    // MARK: header and word choices
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.title2.bold()).textSelection(.enabled)
                if request.kind == .word, !request.contextEnglish.isEmpty, request.contextEnglish != request.term {
                    Text(verbatim: request.contextEnglish).font(.subheadline).textSelection(.enabled)
                }
                if !request.contextJapanese.isEmpty {
                    Text(request.contextJapanese).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if case .failed(let m) = speaker.state { Label(m, systemImage: "speaker.slash.fill").font(.footnote).foregroundStyle(.orange) }
            }
            Spacer()
            Button { speaker.speak(request.term) } label: {
                Image(systemName: speaker.state == .speaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("発音を聞く")
        }
    }

    private var headline: String {
        if case .loaded(.word(let c)) = state { return c.lemma == request.term ? c.lemma : "\(request.term)（原形: \(c.lemma)）" }
        return request.term
    }

    /// The words of the English phrase (and the phrase itself) to pick from without going back to the page.
    private var choices: [LookupRequest] {
        let en = session.request.contextEnglish.isEmpty ? session.request.term : session.request.contextEnglish
        var out: [LookupRequest] = []
        for w in EnglishWords.words(in: en) {
            if let r = LookupRequest.make(kind: .word, term: w, contextEnglish: en, contextJapanese: session.request.contextJapanese) { out.append(r) }
        }
        if out.count > 1, let phrase = LookupRequest.make(kind: .phrase, term: en, contextEnglish: en, contextJapanese: session.request.contextJapanese) { out.append(phrase) }
        return out
    }

    private var chips: some View {
        FlowLayout(spacing: 8) {
            ForEach(choices, id: \.id) { r in
                Button { request = r; saved = .none } label: {
                    Text(verbatim: r.kind == .phrase ? "句全体" : r.term).font(.subheadline)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(r.id == request.id ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(r.id == request.id ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.kind == .phrase ? "句全体の意味" : "単語 \(r.term)")
                .accessibilityAddTraits(r.id == request.id ? .isSelected : [])
            }
        }
    }

    /// Under the card: who made it (the engine that was used, not just the one chosen now).
    private var aiNotice: String {
        var who = "AI が"
        if case .loaded(let card) = state { who = "AI（\(card.makerName)）が" }
        else { who = "AI（\(model.meaningEngine == .mac ? "Mac のローカルモデル" : "iPhone の Apple Intelligence")）が" }
        return who + "作成した説明です。誤りがあるかもしれないので、気になるときは「標準辞書」でも確認してください。"
    }

    // MARK: content
    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 10) { ProgressView(); Text("調べています…（数秒〜10 秒ほどかかります）").foregroundStyle(.secondary) }
                .padding(.vertical, 20)
        case .failed(let f):
            VStack(alignment: .leading, spacing: 10) {
                Label(f.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                HStack {
                    Button("もう一度") { Task { await load() } }.buttonStyle(.bordered).frame(minHeight: 44)
                }
            }
        case .loaded(let card):
            CardContent(card: card)
            moreSection(card)
        }
    }

    /// The second step (an example, common expressions / points, synonyms): only when asked for, because it takes a few seconds more.
    @ViewBuilder private func moreSection(_ card: DefinitionCard) -> some View {
        let has: Bool = { switch card { case .word(let c): return c.hasMore; case .phrase(let c): return c.hasMore } }()
        if !has {
            switch more {
            case .idle:
                Button { Task { await loadMore(card) } } label: {
                    Label(request.kind == .word ? "例文・よく使う形を見る" : "ポイント・言い換え・例文を見る", systemImage: "text.book.closed").frame(minHeight: 44)
                }.buttonStyle(.bordered)
            case .loading:
                HStack(spacing: 10) { ProgressView(); Text("調べています…（数秒）").foregroundStyle(.secondary) }
            case .failed(let f):
                VStack(alignment: .leading, spacing: 6) {
                    Label(f.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                    Button("もう一度") { Task { await loadMore(card) } }.buttonStyle(.bordered).frame(minHeight: 44)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if case .failed(let message) = saved { Text(message).font(.footnote).foregroundStyle(.red) }
            Button { save() } label: {
                Label(saveLabel, systemImage: saved == .saved || saved == .duplicate ? "checkmark" : "tray.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var canSave: Bool {
        guard saved != .saved && saved != .duplicate else { return false }
        if showsDictionary { return true }                        // a word from the dictionary tab is saved with its Japanese context
        if case .loaded = state { return true }
        return false
    }
    private var saveLabel: String {
        switch saved {
        case .saved: return session.existingEntry == nil ? (showsDictionary && model.settings.autoMeaning ? "保存しました（意味は裏で調べます）" : "保存しました") : "辞書の項目に追加しました"
        case .duplicate: return "保存済みです"
        default: return session.existingEntry == nil ? (showsDictionary ? "単語を辞書に保存（原文つき）" : "辞書に保存") : "辞書の項目に追加"
        }
    }

    // MARK: actions
    /// True when the sheet shows what it was opened for (a word chosen with a chip is only shown, never written to the entry).
    private var isOriginalRequest: Bool { request.id == session.request.id }

    private func load() async {
        let asked = request.id
        state = .loading; more = .idle
        let outcome = await model.service.define(request)
        if Task.isCancelled || request.id != asked { return }          // the person has moved on to another word
        switch outcome {
        case .success(let card):
            state = .loaded(card)
            if let id = session.existingEntry, isOriginalRequest {          // a lookup from a saved entry updates that entry
                saved = model.attachCard(entryID: id, card: card) ? .saved : .failed(model.dictionaryProblem ?? "辞書を保存できませんでした")
            }
        case .failure(let f):
            if f != .cancelled { state = .failed(f) }
        case .more:
            state = .failed(.invalidResponse)
        }
    }

    private func loadMore(_ card: DefinitionCard) async {
        let asked = request.id
        more = .loading
        let sense: String = { if case .word(let c) = card { return c.contextMeaning }; return "" }()
        let outcome = await model.service.define(request, more: true, sense: sense)
        if Task.isCancelled || request.id != asked { return }          // a slow answer for another word must not overwrite this one
        switch outcome {
        case .more(let m):
            let merged = card.merging(m)
            state = .loaded(merged); more = .idle
            if saved == .saved || saved == .duplicate {                      // already in the dictionary: it gets the new part too
                switch model.saveLookedUp(card: merged, request: request, session: session) {
                case .failed(let message): saved = .failed(message)
                default: break
                }
            }
        case .failure(let f):
            if f != .cancelled { more = .failed(f) }
        case .success:
            more = .failed(.invalidResponse)
        }
    }

    private func save() {
        let outcome: AppModel.SaveOutcome
        if showsDictionary { outcome = model.saveWordWithContext(request: request, session: session) }
        else if case .loaded(let card) = state { outcome = model.saveLookedUp(card: card, request: request, session: session) }
        else { return }
        switch outcome {
        case .saved: saved = .saved
        case .duplicate: saved = .duplicate
        case .failed(let m): saved = .failed(m)
        }
    }
}

/// The body of a card, also used by the dictionary's detail screen.
struct CardContent: View {
    let card: DefinitionCard

    var body: some View {
        switch card {
        case .word(let c): word(c)
        case .phrase(let c): phrase(c)
        }
    }

    private func word(_ c: WordCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !c.pos.isEmpty { Text(c.pos).font(.caption).padding(.horizontal, 8).padding(.vertical, 2).background(Color(.tertiarySystemFill), in: Capsule()) }
            section("この文での意味") {
                Text(c.contextMeaning).font(.title3.bold()).textSelection(.enabled)
                if let m = c.matchInSource { Text(verbatim: "原文の「\(m)」にあたります").font(.footnote).foregroundStyle(.secondary) }
                if c.meanings.indices.contains(c.contextIndex), let en = c.meanings[c.contextIndex].exampleEn {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(en).font(.subheadline).textSelection(.enabled)
                        if let ja = c.meanings[c.contextIndex].exampleJa { Text(ja).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.top, 2)
                }
            }
            let others = c.meanings.enumerated().filter { $0.offset != c.contextIndex }
            if !others.isEmpty {
                section("ほかの意味") {
                    ForEach(others, id: \.offset) { _, m in Text(verbatim: "・\(m.meaning)").textSelection(.enabled) }
                }
            }
            if !c.phrases.isEmpty { section("よく使う形") { Text(c.phrases.joined(separator: "  ・  ")).textSelection(.enabled) } }
            if let n = c.note { section("ポイント") { Text(n).textSelection(.enabled) } }
        }
    }

    private func phrase(_ c: PhraseCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            section("意味") { Text(c.meaning).font(.title3.bold()).textSelection(.enabled) }
            if let n = c.nuance { section("ニュアンス") { Text(n).textSelection(.enabled) } }
            if !c.points.isEmpty {
                section("ポイント") {
                    ForEach(Array(c.points.enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.expr).font(.body.bold()).textSelection(.enabled)
                            if !p.note.isEmpty { Text(p.note).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
            }
            if !c.synonyms.isEmpty { section("言い換え") { Text(c.synonyms.joined(separator: "  ・  ")).textSelection(.enabled) } }
            if !c.examples.isEmpty {
                section("例文") {
                    ForEach(Array(c.examples.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.en).textSelection(.enabled)
                            if !e.ja.isEmpty { Text(e.ja).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Wraps its children onto several lines (the word choices).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, p) in result.origins.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// The iPhone's own dictionary (the English dictionaries downloaded in Settings). It shows an option to download
/// one when none is installed.
struct SystemDictionaryView: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ vc: UIReferenceLibraryViewController, context: Context) {}
}

/// Reads an English word or phrase aloud with the voices on the phone (offline). It says what went wrong (no English voice,
/// the audio could not start) instead of staying silent. A better voice can be downloaded in
/// Settings > Accessibility > Spoken Content > Voices.
@MainActor final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    enum State: Equatable { case idle, speaking, failed(String) }

    @Published private(set) var state: State = .idle
    private(set) var startedCount = 0          // for the self-test: did the speech really start?
    private let synth = AVSpeechSynthesizer()
    private var previousCategory: AVAudioSession.Category?
    private var watchdog: Task<Void, Never>?
    override private init() { super.init(); synth.delegate = self }

    /// The best English voice installed: premium > enhanced > default, en-US first.
    static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        func score(_ v: AVSpeechSynthesisVoice) -> Int { v.quality.rawValue * 10 + (v.language == "en-US" ? 2 : (v.language == "en-GB" ? 1 : 0)) }
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.max { score($0) < score($1) }
    }

    func speak(_ text: String) {
        watchdog?.cancel()
        guard !text.isEmpty else { return }
        guard let voice = Self.bestEnglishVoice() else {
            state = .failed("英語の音声が iPhone にありません。設定 > アクセシビリティ > 読み上げコンテンツ > 声 で、英語の声をダウンロードしてください")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            if previousCategory == nil { previousCategory = session.category }
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])      // plays even in silent mode
            try session.setActive(true)
        } catch {
            state = .failed("音声を再生できませんでした（オーディオを準備できません: \((error as NSError).code)）")
            return
        }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        u.volume = 1
        let started = startedCount
        state = .speaking
        synth.speak(u)
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.startedCount == started else { return }
            self.state = .failed("音声が始まりませんでした。音量、Bluetooth の接続、「読み上げコンテンツ」の設定を確認してください")
            self.synth.stopSpeaking(at: .immediate)
            self.restoreAudioSession()
        }
    }

    private func restoreAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let c = previousCategory { try? session.setCategory(c) }          // the page's own sound goes back to its usual rules
        previousCategory = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.startedCount += 1; self.watchdog?.cancel(); self.state = .speaking }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.state == .speaking { self.state = .idle }; self.restoreAudioSession() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.state == .speaking { self.state = .idle } }
    }
}
