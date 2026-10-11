import XCTest
@testable import MazemazeCore

final class AddressInputTests: XCTestCase {
    func c(_ s: String) -> AddressInput { AddressInput.classify(s) }

    func testWebAddresses() {
        XCTAssertEqual(c("https://news.yahoo.co.jp/articles/a"), .url(URL(string: "https://news.yahoo.co.jp/articles/a")!))
        XCTAssertEqual(c("  http://example.com/a  "), .url(URL(string: "http://example.com/a")!))
        XCTAssertEqual(c("x.com"), .url(URL(string: "https://x.com")!))
        XCTAssertEqual(c("news.yahoo.co.jp/path?q=1"), .url(URL(string: "https://news.yahoo.co.jp/path?q=1")!))
        XCTAssertEqual(c("example.com:8080/a"), .url(URL(string: "https://example.com:8080/a")!))
        XCTAssertEqual(c("192.168.0.1"), .url(URL(string: "https://192.168.0.1")!))
    }

    func testWordsBecomeASearch() {
        XCTAssertEqual(c("swift concurrency"), .search("swift concurrency"))
        XCTAssertEqual(c("東京の天気"), .search("東京の天気"))
        XCTAssertEqual(c("twitter"), .search("twitter"))
        XCTAssertEqual(c("e.g. something with spaces"), .search("e.g. something with spaces"))
        XCTAssertEqual(c(".com"), .search(".com"))
        XCTAssertEqual(c("3.5度"), .search("3.5度"))                  // Japanese words with a dot are not addresses (nothing leaves except as a search)
        XCTAssertEqual(c("円.の価値"), .search("円.の価値"))
        XCTAssertEqual(c("trailing."), .search("trailing."))
    }

    func testDangerousOrBrokenInputIsRejectedNotSearched() {
        for s in ["", "   ", "javascript:alert(1)", "JAVASCRIPT:alert(1)", "file:///etc/passwd", "data:text/html,hi", "view-source:https://a.com",
                  "ftp://example.com/", "tel:0312345678", "mailto:a@b.com", "https://", "http://", "https:///x", "https://exa mple.com", "a\u{0}b", "line1\nline2", "https:example.com"] {
            XCTAssertEqual(c(s), .rejected, s)
        }
    }

    func testSearchURLEncodesTheWords_andGoogleIsTheDefault() {
        let u = AddressInput.searchURL(for: "a b&c=d 日本語")!
        XCTAssertEqual(u.host, "www.google.com"); XCTAssertEqual(u.scheme, "https"); XCTAssertEqual(u.path, "/search")
        XCTAssertEqual(URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a b&c=d 日本語")
        XCTAssertFalse(u.absoluteString.contains(" "))
        XCTAssertFalse(u.absoluteString.contains("&c=d"), "the & in the words is encoded, not a second parameter")
    }

    func testEveryEngineBuildsAnHttpsResultsPageWithItsOwnQueryName() {
        let expected: [SearchEngine: (host: String, name: String)] = [
            .google: ("www.google.com", "q"), .yahooJapan: ("search.yahoo.co.jp", "p"), .bing: ("www.bing.com", "q"), .duckDuckGo: ("duckduckgo.com", "q")]
        for e in SearchEngine.allCases {
            let u = AddressInput.searchURL(for: "東京の天気", engine: e)!
            XCTAssertEqual(u.scheme, "https"); XCTAssertEqual(u.host, expected[e]?.host)
            let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.name, expected[e]?.name); XCTAssertEqual(items.first?.value, "東京の天気")
            XCTAssertFalse(e.title.isEmpty)
        }
    }

    func testTheSearchEngineIsStoredAndJunkFallsBackToGoogle() {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.searchEngine, .google)
        s.searchEngine = .yahooJapan
        XCTAssertEqual(s.searchEngine, .yahooJapan)
        d.set("example-evil", forKey: "mazemaze.searchEngine")
        XCTAssertEqual(s.searchEngine, .google)
    }
}
