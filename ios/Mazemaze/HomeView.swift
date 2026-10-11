import SwiftUI
import MazemazeCore

/// Mazemaze's own start screen: what translates on this iPhone, favorites, recent sites. Nothing is opened for you.
struct HomeView: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @State private var confirmClear = false
    @Environment(\.scenePhase) private var scenePhase

    private static let suggestion = (title: "Yahoo!ニュース", url: URL(string: "https://news.yahoo.co.jp/")!)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusCard
                pasteCard
                favoritesSection
                recentsSection
                privacyNote
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .onAppear { model.refreshEngineStatus() }
        .onChange(of: scenePhase) { phase in if phase == .active { model.refreshEngineStatus() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mazemaze").font(.largeTitle).bold()
            Text("日本語の記事を、英語混じりで読むためのブラウザです。下のアドレス欄に URL か検索語を入力するか、ここから選んでください。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: status
    /// What translates on this iPhone, and anything that has to be done before it can (data to download, Apple Intelligence to switch on).
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: pageProblem == nil ? "iphone" : "exclamationmark.triangle.fill").foregroundStyle(pageProblem == nil ? Color.green : Color.orange).accessibilityHidden(true)
                Text(pageProblem == nil ? "ページの翻訳は iPhone の中で行います" : "翻訳の準備が必要です").font(.headline)
            }
            Text(pageProblem ?? "通信は使わず、ページの文章は iPhone の外に出ません。").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label("ページの翻訳: \(model.translationEngine.title)", systemImage: "doc.plaintext")
                Label("単語の意味（AI）: Apple Intelligence" + (model.foundationModelsProblem.map { "（\($0)）" } ?? ""), systemImage: "character.book.closed")
            }
            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("設定を開く") { showSettings = true }.buttonStyle(.bordered).frame(minHeight: 44)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var pageProblem: String? {
        switch model.translationEngine {
        case .foundationModels: return model.foundationModelsProblem
        case .appleTranslation: return model.appleTranslationInstalled ? nil : model.appleTranslationStatus
        }
    }

    // MARK: paste and translate
    private var pasteCard: some View {
        Button { model.openPaste() } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("貼り付けて翻訳").font(.headline)
                    Text("コピーした日本語の文章（X の投稿、記事の一部など）を英語混じりにします。").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .frame(minHeight: 56)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("コピーした文章を貼り付ける画面を開きます")
    }

    // MARK: favorites
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("お気に入り").font(.title3).bold()
            if model.bookmarks.favorites.isEmpty {
                Text("まだありません。ページを開いて、下のメニュー（⋯）の「お気に入りに追加」で登録できます。").font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(model.bookmarks.favorites) { fav in
                    Button { tab.navigate(to: fav.url) } label: { siteTile(title: fav.title, host: fav.url.host ?? "") }
                        .buttonStyle(.plain)
                        .contextMenu { Button(role: .destructive) { model.removeFavorite(id: fav.id) } label: { Label("お気に入りから削除", systemImage: "trash") } }
                        .accessibilityAction(named: "お気に入りから削除") { model.removeFavorite(id: fav.id) }
                }
            }
            if !model.bookmarks.isFavorite(Self.suggestion.url) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("おすすめの候補（記事を開くと英語が混ざります。トップは見出しの一覧なので、ほとんど変わりません）").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button { tab.navigate(to: Self.suggestion.url) } label: { siteTile(title: Self.suggestion.title, host: "news.yahoo.co.jp") }.buttonStyle(.plain)
                        Button("追加") { model.addFavorite(url: Self.suggestion.url, title: Self.suggestion.title) }.buttonStyle(.bordered).frame(minHeight: 44)
                            .accessibilityLabel("\(Self.suggestion.title)をお気に入りに追加")
                    }
                    Text("起動時に自動で開くことはありません。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func siteTile(title: String, host: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).bold().lineLimit(2).multilineTextAlignment(.leading)
            Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: recents
    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近開いたサイト").font(.title3).bold()
                Spacer()
                if !model.bookmarks.recents.isEmpty {
                    Button("履歴を消去") { confirmClear = true }.font(.footnote).frame(minHeight: 44)
                }
            }
            if !model.recentsEnabled {
                Text("オフになっています（設定でオンにできます）。").font(.footnote).foregroundStyle(.secondary)
            } else if model.bookmarks.recents.isEmpty {
                Text("ここに表示されます。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.bookmarks.recents.prefix(10)) { site in
                Button { tab.navigate(to: site.url) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.title).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                        Text(site.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .confirmationDialog("最近開いたサイトと、保存されたタブの情報を消去しますか？（ログイン情報や Cookie は消えません）", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("履歴を消去", role: .destructive) { model.clearHistory() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("検索について", systemImage: "magnifyingglass").font(.footnote).bold()
            Text("アドレス欄に語句を入力して検索すると、その語句が、設定で選んだ検索サービス（\(model.settings.searchEngine.title)）に送られます。ページ本文の翻訳は、iPhone の中だけで処理されます。")
                .font(.footnote).foregroundStyle(.secondary)
            Label("保存されるもの", systemImage: "internaldrive").font(.footnote).bold()
            Text("お気に入りと最近のサイトは、この iPhone にだけ保存されます。最近のサイトとタブの復元には、ログイン・メール・ネットバンキングなどを除いた公開ページの URL（検索条件や認証情報は含みません）だけが保存されます。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}
