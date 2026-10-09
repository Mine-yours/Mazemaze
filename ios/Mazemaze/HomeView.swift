import SwiftUI
import MazemazeCore

/// Mazemaze's own start screen: connection state, favorites, recent sites. Nothing is opened for you.
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
                connectionCard
                favoritesSection
                recentsSection
                privacyNote
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .onAppear { model.refreshConnectionStatus() }
        .onChange(of: scenePhase) { phase in if phase == .active { model.refreshConnectionStatus() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mazemaze").font(.largeTitle).bold()
            Text("日本語の記事を、英語混じりで読むためのブラウザです。上のアドレス欄に URL か検索語を入力するか、下から選んでください。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: connection
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: connectionSymbol).foregroundStyle(connectionColor)
                Text(connectionTitle).font(.headline)
                Spacer()
                if model.checkingConnection { ProgressView().controlSize(.small) }
            }
            Text(connectionDetail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.needsSetup {
                Label(model.settings.pinnedFingerprint != nil ? "通信は暗号化されています（証明書で Mac を確認）" : "通信は暗号化されていません（HTTP）。自宅の Wi-Fi だけで使ってください",
                      systemImage: model.settings.pinnedFingerprint != nil ? "lock.fill" : "lock.open")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button(model.needsSetup ? "サーバーを設定する" : "設定を開く") { showSettings = true }.buttonStyle(.bordered).frame(minHeight: 44)
                if !model.needsSetup {
                    Button("もう一度確認") { model.refreshConnectionStatus() }.buttonStyle(.bordered).frame(minHeight: 44).disabled(model.checkingConnection)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var connectionSymbol: String {
        if model.needsSetup { return "exclamationmark.triangle.fill" }
        switch model.connection?.state { case .ok?: return "checkmark.circle.fill"; case .warning?: return "exclamationmark.triangle.fill"; case .failed?: return "xmark.octagon.fill"; case nil: return "questionmark.circle" }
    }
    private var connectionColor: Color {
        if model.needsSetup { return .orange }
        switch model.connection?.state { case .ok?: return .green; case .warning?: return .orange; case .failed?: return .red; case nil: return .secondary }
    }
    private var connectionTitle: String {
        if model.needsSetup { return "翻訳サーバー（Mac）が未設定です" }
        switch model.connection?.state { case .ok?: return "Mac に接続できています"; case .warning?: return "Mac に接続できましたが、注意が必要です"; case .failed?: return "Mac に接続できません"; case nil: return "接続を確認しています…" }
    }
    private var connectionDetail: String {
        if model.needsSetup { return "Mac で ./scripts/run_lan.sh を実行し、表示された QR を iPhone の「カメラ」で読み取ってください（初回だけ）。読み取れないときは、設定から文字列を貼り付けられます。" }
        return model.connection?.message ?? "しばらくお待ちください。"
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
            Text("アドレス欄に語句を入力して検索すると、その語句が外部の検索サービス（\(AddressInput.searchServiceName)）に送られます。送る前に確認が出ます。ページ本文の翻訳は、Mac の中だけで処理されます。")
                .font(.footnote).foregroundStyle(.secondary)
            Label("保存されるもの", systemImage: "internaldrive").font(.footnote).bold()
            Text("お気に入りと最近のサイトは、この iPhone にだけ保存されます。最近のサイトとタブの復元には、ログイン・メール・ネットバンキングなどを除いた公開ページの URL（検索条件や認証情報は含みません）だけが保存されます。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}
