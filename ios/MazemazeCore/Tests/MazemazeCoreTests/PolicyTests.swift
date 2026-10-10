import XCTest
@testable import MazemazeCore

final class SitePolicyTests: XCTestCase {
    let policy = SitePolicy()
    func allowed(_ s: String) -> Bool { policy.decision(for: URL(string: s)).isAllowed }

    func testAllowedPages() {
        for s in ["https://x.com/home", "https://x.com/", "https://x.com/someuser", "https://x.com/someuser/status/123", "https://x.com/search?q=a",
                  "https://mobile.x.com/home", "https://twitter.com/home", "https://news.yahoo.co.jp/articles/abc", "https://news.yahoo.co.jp/",
                  "https://X.COM/home", "https://x.com./home", "https://x.com/hashtag/foo", "https://x.com/explore"] {
            XCTAssertTrue(allowed(s), s)
        }
    }
    func testHostSpoofing() {
        for s in ["https://x.com.evil.com/", "https://evilx.com/", "https://notx.com/", "https://x.com@evil.com/", "https://evil.com/x.com",
                  "https://evil.com/?u=x.com", "https://news.yahoo.co.jp.evil.com/", "https://yahoo.co.jp/", "https://login.yahoo.co.jp/",
                  "https://х.com/", "https://xn--e1a.com/"] {
            XCTAssertFalse(allowed(s), s)
        }
    }
    func testSchemesAndPorts() {
        for s in ["http://x.com/home", "ftp://x.com/", "file:///x.com", "about:blank", "data:text/html,hi", "blob:https://x.com/uuid", "https://x.com:8443/home"] {
            XCTAssertFalse(allowed(s), s)
        }
        XCTAssertTrue(allowed("https://x.com:443/home"))
        XCTAssertFalse(policy.decision(for: nil).isAllowed)
    }
    func testDeniedPaths() {
        for s in ["https://x.com/login", "https://x.com/LOGIN", "https://x.com/login/", "https://x.com/login?x=1", "https://x.com//login",
                  "https://x.com/%6Cogin", "https://x.com/i/flow/login", "https://x.com/i/flow/../flow/login", "https://x.com/messages", "https://x.com/messages/123",
                  "https://x.com/settings/account", "https://x.com/account/access", "https://x.com/compose/post", "https://x.com/i/chat/x",
                  "https://x.com/home/../login", "https://x.com/i/oauth2/authorize", "https://news.yahoo.co.jp/login", "https://news.yahoo.co.jp/account"] {
            XCTAssertFalse(allowed(s), s)
        }
        XCTAssertTrue(allowed("https://news.yahoo.co.jp/loginfoo"))   // whole-segment match only
        XCTAssertTrue(allowed("https://x.com/messages_news"))        // a handle, not the DM page
    }
    func testXIsAllowListBased() {
        for s in ["https://x.com/notifications", "https://x.com/bookmarks", "https://x.com/i/anything", "https://x.com/some-user-with-hyphen",
                  "https://x.com/waytoolonghandle12345", "https://x.com/tos", "https://x.com/privacy"] {
            XCTAssertFalse(allowed(s), s)
        }
    }
    func testProfiles() {
        XCTAssertEqual(policy.decision(for: URL(string: "https://x.com/home")), .allowed(profile: .x))
        XCTAssertEqual(policy.decision(for: URL(string: "https://news.yahoo.co.jp/")), .allowed(profile: .generic))
    }
    func testLocalhostOnlyWhenDebugFlagSet() {
        XCTAssertFalse(policy.decision(for: URL(string: "http://localhost:8080/a.html")).isAllowed)
        XCTAssertFalse(policy.decision(for: URL(string: "https://localhost/a.html")).isAllowed)
        let dbg = SitePolicy(allowInsecureLocalhost: true)
        XCTAssertTrue(dbg.decision(for: URL(string: "http://localhost:8080/a.html")).isAllowed)
        XCTAssertTrue(dbg.decision(for: URL(string: "http://127.0.0.1:8080/a.html")).isAllowed)
        XCTAssertFalse(dbg.decision(for: URL(string: "http://192.168.0.1/a.html")).isAllowed)
        XCTAssertFalse(dbg.decision(for: URL(string: "http://localhost.evil.com/a.html")).isAllowed)
    }
    func testEntryNormalization() {
        XCTAssertEqual(SitePolicy.normalizeEntry(" News.Example.CO.JP. "), "news.example.co.jp")
        for bad in ["com", "co.jp", "jp", "*.com", ".", "", "192.168.0.1", "1.2", "localhost", "ex ample.com", "例え.jp", "a..com", "-a.com", "https://x.com", "x.com/path", "github.io", "blogspot.com", "vercel.app"] {
            XCTAssertNil(SitePolicy.normalizeEntry(bad), bad)
        }
    }
    func testCustomHostsAreSuffixMatchedAtDotBoundary() {
        let p = SitePolicy(allowedHosts: ["example.jp"])
        XCTAssertTrue(p.decision(for: URL(string: "https://www.example.jp/a")).isAllowed)
        XCTAssertFalse(p.decision(for: URL(string: "https://notexample.jp/a")).isAllowed)
        XCTAssertFalse(p.decision(for: URL(string: "https://x.com/home")).isAllowed)
    }
    func testLoginHostLabelsDenied() {
        let p = SitePolicy(allowedHosts: ["example.jp"])
        XCTAssertFalse(p.decision(for: URL(string: "https://login.example.jp/")).isAllowed)
        XCTAssertFalse(p.decision(for: URL(string: "https://accounts.example.jp/")).isAllowed)
    }
}

final class BridgeMessageTests: XCTestCase {
    func parse(_ d: Any) -> Result<BridgeRequest, BridgeError> { BridgeMessage.parse(d) }

    func testValid() {
        XCTAssertEqual(try? parse(["type": "ready"]).get(), .ready)
        XCTAssertEqual(try? parse(["type": "translate", "gen": 3, "text": "日本語のテキスト"]).get(), .translate(gen: 3, text: "日本語のテキスト"))
    }
    func testRejectsMalformed() {
        let bad: [Any] = ["x", 1, NSNull(), [String: Any](), ["type": 1], ["type": "other"], ["type": "ready", "x": 1],
                          ["type": "translate"], ["type": "translate", "gen": 1, "text": "あ", "ratio": 0.3],
                          ["type": "translate", "gen": "1", "text": "あ"], ["type": "translate", "gen": -1, "text": "あ"],
                          ["type": "translate", "gen": 1.5, "text": "あ"], ["type": "translate", "gen": true, "text": "あ"],
                          ["type": "translate", "gen": 1e300, "text": "あ"], ["type": "translate", "gen": Double.nan, "text": "あ"],
                          ["type": "translate", "gen": 1, "text": 5], ["type": "translate", "gen": 1, "text": NSNull()],
                          ["type": "translate", "gen": 1, "text": ""], ["type": "translate", "gen": 1, "text": "  \n\t"],
                          ["type": "translate", "gen": 1, "text": "あ\u{0}い"]]
        for b in bad { XCTAssertThrowsError(try parse(b).get(), "\(b)") }
    }
    func testTextLengthCountsUnicodeScalars() {
        let thousand = String(repeating: "あ", count: 1000)
        XCTAssertNotNil(try? parse(["type": "translate", "gen": 0, "text": thousand]).get())
        XCTAssertThrowsError(try parse(["type": "translate", "gen": 0, "text": thousand + "あ"]).get())
        // One grapheme (Character) but 7 scalars: the server counts scalars, so this must too.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        let nearLimit = String(repeating: "あ", count: 995) + family   // 995 + 7 = 1002 scalars
        XCTAssertThrowsError(try parse(["type": "translate", "gen": 0, "text": nearLimit]).get())
    }
}
