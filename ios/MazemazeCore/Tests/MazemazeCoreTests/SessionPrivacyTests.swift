import XCTest
@testable import MazemazeCore

final class SessionPrivacyTests: XCTestCase {
    func keep(_ s: String) -> String? { URL(string: s).flatMap(SessionPrivacy.persistableURL)?.absoluteString }

    func testOrdinaryPublicPagesAreKeptWithoutQueryOrFragment() {
        XCTAssertEqual(keep("https://news.yahoo.co.jp/articles/abc123?source=top&utm_x=1#comments"), "https://news.yahoo.co.jp/articles/abc123")
        XCTAssertEqual(keep("https://NEWS.Yahoo.co.jp/articles/abc"), "https://news.yahoo.co.jp/articles/abc")
        XCTAssertEqual(keep("https://www3.nhk.or.jp/news/"), "https://www3.nhk.or.jp/news/")
        XCTAssertEqual(keep("https://example.com"), "https://example.com/")
        XCTAssertEqual(keep("https://example.com:443/a"), "https://example.com/a")
        XCTAssertEqual(keep("https://example.com./a"), "https://example.com/a")
    }

    func testSecretsInTheQueryNeverReachDisk() {
        for q in ["token=abc", "ACCESS_TOKEN=x", "api_key=1", "sessionid=9", "code=123", "X-Amz-Signature=abc", "%74oken=abc", "a=1&jwt=xyz"] {
            let kept = keep("https://example.com/page?\(q)")
            XCTAssertEqual(kept, "https://example.com/page", q)     // the whole query is dropped, so nothing survives
            XCTAssertFalse((kept ?? "").contains("abc") || (kept ?? "").contains("xyz"), q)
        }
    }

    func testRefusedSchemesAndForms() {
        for s in ["http://example.com/a", "javascript:alert(1)", "data:text/html,hi", "blob:https://a.com/x", "file:///etc/passwd",
                  "about:blank", "ftp://example.com/", "https://user:pw@example.com/a", "https://user@example.com/a",
                  "https://example.com:8443/a", "https://example.com:80/a", "https:///nohost", "x-safari-https://example.com/"] {
            XCTAssertNil(keep(s), s)
        }
        XCTAssertNil(SessionPrivacy.persistableURL(nil))
    }

    func testPrivateAndLocalAddressesAreNotStored() {
        for s in ["https://192.168.0.1/admin", "https://10.0.0.5/a", "https://127.0.0.1/a", "https://localhost/a", "https://[::1]/a",
                  "https://router.local/a", "https://nas.home/a", "https://wiki.internal/a", "https://printer.lan/a", "https://2130706433/a",
                  "https://intranet.corp/a", "https://example/a", "https://xn--a.local/a"] {
            XCTAssertNil(keep(s), s)
        }
    }

    func testLoginMailBankAndAccountPagesAreNotStored() {
        for s in ["https://login.yahoo.co.jp/config/login", "https://accounts.google.com/signin", "https://mail.google.com/mail/u/0/", "https://webmail.example.com/",
                  "https://bank.example.co.jp/", "https://secure.example.com/a", "https://pay.example.com/a", "https://example.com/login", "https://example.com/LOGIN/",
                  "https://example.com/%6Cogin", "https://example.com/i/flow/login", "https://example.com/account/security", "https://example.com/settings/profile",
                  "https://example.com/a/../login", "https://example.com/shop/cart", "https://example.com/checkout/step1", "https://example.com/user/reset/ABC",
                  "https://example.com/messages/123", "https://example.com/oauth2/authorize", "https://example.com/mypage"] {
            XCTAssertNil(keep(s), s)
        }
        XCTAssertNotNil(keep("https://example.com/loginfoo"))          // whole path segments only
        XCTAssertNotNil(keep("https://example.com/news/mailing-list-history"))
    }

    func testLengthLimits() {
        XCTAssertNotNil(keep("https://example.com/" + String(repeating: "a", count: 400)))
        XCTAssertNil(keep("https://example.com/" + String(repeating: "a", count: 600)))
        XCTAssertNil(keep("https://example.com/" + String(repeating: "あ", count: 300)))          // percent-encoded length counts
        let start = Date()
        _ = keep("https://example.com/" + String(repeating: "a/", count: 20000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testTitlesThatCouldHoldSearchWordsOrPostsAreNeverStored() {
        let hosts = ["news.yahoo.co.jp", "x.com"]
        func title(_ s: String) -> String { let u = URL(string: s)!; return SessionPrivacy.storableTitle(for: SessionPrivacy.persistableURL(u) ?? u, title: "秘密の語の検索結果", allowedHosts: hosts, original: u) }
        XCTAssertEqual(title("https://news.yahoo.co.jp/search?p=秘密の語"), "news.yahoo.co.jp")
        XCTAssertEqual(title("https://news.yahoo.co.jp/articles/a?utm_source=x"), "news.yahoo.co.jp")
        XCTAssertEqual(title("https://news.yahoo.co.jp/articles/a#c"), "news.yahoo.co.jp")
        XCTAssertEqual(title("https://x.com/someone/status/123"), "x.com")
        XCTAssertEqual(title("https://x.com/search"), "x.com")
        XCTAssertEqual(title("https://news.yahoo.co.jp/articles/a"), "秘密の語の検索結果")        // an ordinary article keeps its title
        var d = BookmarkData()
        d.recordVisit(url: URL(string: "https://news.yahoo.co.jp/articles/a?q=秘密"), title: "秘密の語", allowedHosts: hosts)
        XCTAssertEqual(d.recents.first?.title, "news.yahoo.co.jp")
        let snap = TabsSnapshot.make(tabs: [(URL(string: "https://news.yahoo.co.jp/articles/a?q=秘密"), "秘密の語")], activeIndex: 0, allowedHosts: hosts)
        XCTAssertFalse(String(data: snap.encoded()!, encoding: .utf8)!.contains("秘密"))
    }

    func testOnlyNewsSitesEverKeepATitleEvenIfThePersonAddsOtherSitesToTranslate() {
        let u = URL(string: "https://forum.example.jp/thread/42")!
        XCTAssertEqual(SessionPrivacy.storableTitle(for: u, title: "誰かの書き込み", allowedHosts: SessionPrivacy.titleHosts), "forum.example.jp")
        XCTAssertEqual(SessionPrivacy.storableTitle(for: URL(string: "https://news.yahoo.co.jp/articles/a")!, title: "記事", allowedHosts: SessionPrivacy.titleHosts), "記事")
        XCTAssertEqual(SessionPrivacy.storableTitle(for: URL(string: "https://news.yahoo.co.jp/tags/foo")!, title: "タグ", allowedHosts: SessionPrivacy.titleHosts), "news.yahoo.co.jp")
        XCTAssertEqual(SessionPrivacy.storableTitle(for: URL(string: "https://news.yahoo.co.jp/articles/a")!, title: "a\u{202E}b\u{200F}c", allowedHosts: SessionPrivacy.titleHosts), "abc")
    }

    func testTitlesAreStoredOnlyForTranslatedSites() {
        let u = URL(string: "https://news.yahoo.co.jp/articles/a")!
        XCTAssertEqual(SessionPrivacy.storableTitle(for: u, title: "記事のタイトル\n", allowedHosts: ["news.yahoo.co.jp"]), "記事のタイトル")
        let mail = URL(string: "https://example.com/news")!
        XCTAssertEqual(SessionPrivacy.storableTitle(for: mail, title: "受信トレイ (3) - 私のメール", allowedHosts: ["news.yahoo.co.jp"]), "example.com")
        XCTAssertEqual(SessionPrivacy.storableTitle(for: u, title: nil, allowedHosts: ["news.yahoo.co.jp"]), "news.yahoo.co.jp")
        XCTAssertEqual(SessionPrivacy.storableTitle(for: u, title: String(repeating: "長", count: 300), allowedHosts: ["news.yahoo.co.jp"]).count, 80)
        XCTAssertEqual(SessionPrivacy.storableTitle(for: u, title: "a\u{0}b\u{200B}c", allowedHosts: ["news.yahoo.co.jp"]), "abc")
    }
}

final class FavoritesTests: XCTestCase {
    func url(_ s: String) -> URL { URL(string: s)! }

    func testFavoriteKeepsAPlainQueryButDropsTrackingAndRefusesCredentials() {
        XCTAssertEqual(Favorites.favoriteURL(url("https://example.com/search?q=swift&utm_source=x&fbclid=1#top"))?.absoluteString, "https://example.com/search?q=swift")
        for s in ["https://example.com/a?token=1", "https://example.com/a?x=1&API_KEY=2", "https://example.com/a?sig=3", "http://example.com/a",
                  "https://user:pw@example.com/a", "https://192.168.0.1/a", "https://login.example.com/a", "https://example.com/login", "javascript:alert(1)"] {
            XCTAssertNil(Favorites.favoriteURL(url(s)), s)
        }
    }

    func testAddingDedupesAndMovesToFront() {
        var d = BookmarkData()
        XCTAssertTrue(d.addFavorite(url: url("https://news.yahoo.co.jp/"), title: "Yahoo!ニュース"))
        XCTAssertTrue(d.addFavorite(url: url("https://example.com/a"), title: "A"))
        XCTAssertTrue(d.addFavorite(url: url("https://NEWS.yahoo.co.jp:443/#x"), title: "Yahoo!ニュース 2"))
        XCTAssertEqual(d.favorites.map(\.title), ["Yahoo!ニュース 2", "A"])
        XCTAssertTrue(d.isFavorite(url("https://news.yahoo.co.jp")))
        XCTAssertFalse(d.addFavorite(url: url("http://example.com/b"), title: "B"))
        d.removeFavorite(id: d.favorites[0].id)
        XCTAssertEqual(d.favorites.count, 1)
    }

    func testLimitsAndTitleCleaning() {
        var d = BookmarkData()
        for i in 0..<60 { d.addFavorite(url: url("https://example.com/p\(i)"), title: "t\(i)") }
        XCTAssertEqual(d.favorites.count, Favorites.maxFavorites)
        XCTAssertEqual(d.favorites.first?.title, "t59")
        var e = BookmarkData()
        e.addFavorite(url: url("https://example.com/x"), title: "  \u{0}\n  ")
        XCTAssertEqual(e.favorites.first?.title, "example.com")
    }

    func testRecentsStoreHostAndPathOnlyAndOnlyPrivacySafePages() {
        var d = BookmarkData()
        d.recordVisit(url: url("https://news.yahoo.co.jp/articles/a?secret=1#x"), title: "記事", allowedHosts: ["news.yahoo.co.jp"])
        d.recordVisit(url: url("https://mail.example.com/inbox"), title: "受信箱", allowedHosts: [])
        d.recordVisit(url: url("https://example.com/login"), title: "ログイン", allowedHosts: [])
        d.recordVisit(url: url("https://192.168.0.1/"), title: "ルーター", allowedHosts: [])
        d.recordVisit(url: url("https://example.com/b"), title: "他のサイトのタイトル", allowedHosts: ["news.yahoo.co.jp"])
        XCTAssertEqual(d.recents.map(\.url.absoluteString), ["https://example.com/b", "https://news.yahoo.co.jp/articles/a"])
        XCTAssertEqual(d.recents.map(\.title), ["example.com", "news.yahoo.co.jp"])     // the URL had a query: its title is not kept
        for _ in 0..<30 { for i in 0..<25 { d.recordVisit(url: url("https://example.com/r\(i)"), title: nil, allowedHosts: []) } }
        XCTAssertEqual(d.recents.count, Favorites.maxRecents)
        d.clearRecents()
        XCTAssertTrue(d.recents.isEmpty)
    }

    func testStorageRoundTripIgnoresDamageAndRevalidates() throws {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = BookmarkStorage(defaults: defaults)
        XCTAssertEqual(storage.load(), BookmarkData())
        var d = BookmarkData()
        d.addFavorite(url: url("https://news.yahoo.co.jp/"), title: "Yahoo!ニュース")
        d.recordVisit(url: url("https://news.yahoo.co.jp/articles/a"), title: "記事", allowedHosts: ["news.yahoo.co.jp"])
        storage.save(d)
        XCTAssertEqual(storage.load().favorites.map(\.title), ["Yahoo!ニュース"])
        defaults.set(Data("not json".utf8), forKey: "mazemaze.bookmarks.v1")
        XCTAssertEqual(storage.load(), BookmarkData())          // damaged data: start empty, no crash
        // Tampered / old data containing a private page is filtered on load.
        var bad = BookmarkData()
        bad.favorites = [SavedSite(title: "x", url: url("https://example.com/a?token=1"))]
        bad.recents = [SavedSite(title: "y", url: url("https://example.com/login"))]
        storage.save(bad)
        XCTAssertTrue(storage.load().favorites.isEmpty && storage.load().recents.isEmpty)
        storage.clearAll()
        let dump = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined()
        XCTAssertFalse(dump.contains("yahoo"))
    }
}

final class TabsSnapshotTests: XCTestCase {
    let hosts = ["news.yahoo.co.jp"]
    func url(_ s: String) -> URL? { URL(string: s) }

    func testPrivatePagesComeBackAsTheHomeScreen() {
        let snap = TabsSnapshot.make(tabs: [
            (url("https://news.yahoo.co.jp/articles/a?x=1"), "記事"), (url("https://mail.example.com/inbox"), "受信箱"),
            (url("https://example.com/login"), "ログイン"), (nil, nil), (url("http://example.com/a"), "http"),
        ], activeIndex: 1, allowedHosts: hosts)
        XCTAssertEqual(snap.tabs.map(\.url), ["https://news.yahoo.co.jp/articles/a", nil, nil, nil, nil])
        XCTAssertEqual(snap.tabs[0].title, "news.yahoo.co.jp")
        XCTAssertEqual(snap.activeIndex, 1)
        let dump = String(data: snap.encoded()!, encoding: .utf8)!
        XCTAssertFalse(dump.contains("mail.example") || dump.contains("受信箱") || dump.contains("login") || dump.contains("x=1"))
    }

    func testLimitsAndBadActiveIndex() {
        let many = (0..<12).map { (url("https://example.com/p\($0)") as URL?, "t" as String?) }
        let snap = TabsSnapshot.make(tabs: many, activeIndex: 99, allowedHosts: hosts)
        XCTAssertEqual(snap.tabs.count, 8)
        XCTAssertEqual(snap.activeIndex, 0)
    }

    func testRestoreRevalidatesAndSurvivesGarbage() {
        let good = TabsSnapshot.make(tabs: [(url("https://news.yahoo.co.jp/articles/a"), "記事")], activeIndex: 0, allowedHosts: hosts)
        XCTAssertEqual(TabsSnapshot.restore(from: good.encoded(), allowedHosts: hosts), good)
        XCTAssertNil(TabsSnapshot.restore(from: nil, allowedHosts: hosts))
        XCTAssertNil(TabsSnapshot.restore(from: Data("garbage".utf8), allowedHosts: hosts))
        XCTAssertNil(TabsSnapshot.restore(from: Data("{\"version\":99,\"activeIndex\":0,\"tabs\":[]}".utf8), allowedHosts: hosts))
        XCTAssertNil(TabsSnapshot.restore(from: Data("{\"version\":1,\"activeIndex\":0,\"tabs\":[]}".utf8), allowedHosts: hosts))
        // Hand-edited data with a login URL and an out-of-range index: sanitized on the way in.
        let tampered = "{\"version\":1,\"activeIndex\":7,\"tabs\":[{\"url\":\"https://example.com/login\",\"title\":\"x\"},{\"url\":\"https://user:pw@example.com/a\"}]}"
        let restored = TabsSnapshot.restore(from: Data(tampered.utf8), allowedHosts: hosts)
        XCTAssertEqual(restored?.tabs.map(\.url), [nil, nil])
        XCTAssertEqual(restored?.activeIndex, 0)
        // Saving what was restored again changes nothing (idempotent).
        XCTAssertEqual(TabsSnapshot.restore(from: restored?.encoded(), allowedHosts: hosts), restored)
    }
}
