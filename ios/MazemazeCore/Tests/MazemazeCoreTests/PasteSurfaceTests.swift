import XCTest
@testable import MazemazeCore

final class PasteSurfaceTests: XCTestCase {
    func testPasteURLIsAMatchOnlyForTheExactAddress() {
        XCTAssertTrue(PasteSurface.isPasteURL(PasteSurface.url))
        XCTAssertTrue(PasteSurface.isPasteURL(URL(string: "https://PASTE.mazemaze.invalid")))
        for bad in ["http://paste.mazemaze.invalid/", "https://paste.mazemaze.invalid:8443/", "https://paste.mazemaze.invalid/x",
                    "https://paste.mazemaze.invalid/?q=1", "https://paste.mazemaze.invalid/#a", "https://u@paste.mazemaze.invalid/",
                    "https://x.paste.mazemaze.invalid/", "https://paste.mazemaze.invalid.evil.com/", "https://mazemaze.invalid/"] {
            XCTAssertFalse(PasteSurface.isPasteURL(URL(string: bad)), bad)
        }
        XCTAssertFalse(PasteSurface.isPasteURL(nil))
    }

    func testPolicyAllowsOnlyTheExactPasteAddress() {
        let p = SitePolicy()
        XCTAssertEqual(p.decision(for: PasteSurface.url), .allowed(profile: .generic))
        XCTAssertFalse(p.decision(for: URL(string: "https://paste.mazemaze.invalid/x")).isAllowed)
        XCTAssertFalse(p.decision(for: URL(string: "https://x.paste.mazemaze.invalid/")).isAllowed)
        XCTAssertFalse(p.decision(for: URL(string: "http://paste.mazemaze.invalid/")).isAllowed)
        // Even a user-added allowed host (which normalizeEntry refuses anyway) cannot open the rest of that host.
        let sneaky = SitePolicy(allowedHosts: ["paste.mazemaze.invalid", "mazemaze.invalid"])
        XCTAssertFalse(sneaky.decision(for: URL(string: "https://paste.mazemaze.invalid/other")).isAllowed)
        XCTAssertFalse(sneaky.decision(for: URL(string: "https://a.paste.mazemaze.invalid/")).isAllowed)
        XCTAssertNil(SitePolicy.normalizeEntry("mazemaze.invalid"))
        XCTAssertNil(SitePolicy.normalizeEntry("paste.mazemaze.invalid"))
        XCTAssertNil(SitePolicy.normalizeEntry("foo.test"))
        XCTAssertNil(SitePolicy.normalizeEntry("foo.example"))
        XCTAssertNotNil(SitePolicy.normalizeEntry("news.example.jp"))
    }

    func testWebNavigationNeverReachesThePasteHost() {
        XCTAssertEqual(ExternalNavigation.classify(PasteSurface.url), .blocked)
        XCTAssertEqual(ExternalNavigation.classify(URL(string: "https://a.paste.mazemaze.invalid/x")!), .blocked)
        XCTAssertEqual(ExternalNavigation.classify(URL(string: "https://example.com/")!), .allowInApp)
    }

    func testNothingAboutThePasteSurfaceIsStored() {
        XCTAssertNil(SessionPrivacy.persistableURL(PasteSurface.url))
        XCTAssertNil(SessionPrivacy.persistableURL(URL(string: "https://anything.invalid/a")))
        var data = BookmarkData()
        XCTAssertFalse(data.addFavorite(url: PasteSurface.url, title: "貼り付け"))
        data.recordVisit(url: PasteSurface.url, title: "貼り付け", allowedHosts: ["paste.mazemaze.invalid"])
        XCTAssertTrue(data.recents.isEmpty)
        let snap = TabsSnapshot.make(tabs: [(url: PasteSurface.url, title: "x")], activeIndex: 0, allowedHosts: [])
        XCTAssertNil(snap.tabs.first?.url)
    }

    func testNormalizeKeepsTheTextExactlyApartFromLineEndingsAndEdges() {
        guard case .success(let lines) = PasteSurface.normalize("\r\n  \r\n今日は晴れ。\r\n\r\n 明日は雨 😀 \r\n\n") else { return XCTFail() }
        XCTAssertEqual(lines, ["今日は晴れ。", "", " 明日は雨 😀 "])
        XCTAssertEqual(lines.joined(separator: "\n"), "今日は晴れ。\n\n 明日は雨 😀 ")
        guard case .success(let one) = PasteSurface.normalize("a\u{0}b\rc") else { return XCTFail() }
        XCTAssertEqual(one, ["ab", "c"])
    }

    func testNormalizeRejectsEmptyAndTooLongInput() {
        XCTAssertEqual(PasteSurface.normalize("   \n\r\n\t "), .failure(.empty))
        XCTAssertEqual(PasteSurface.normalize(""), .failure(.empty))
        let max = String(repeating: "あ", count: PasteSurface.maxCharacters)
        guard case .success = PasteSurface.normalize(max) else { return XCTFail("exactly the limit is fine") }
        XCTAssertEqual(PasteSurface.normalize(max + "あ"), .failure(.tooLong(PasteSurface.maxCharacters + 1)))
    }

    func testJapaneseHint() {
        XCTAssertTrue(PasteSurface.containsJapanese(["Hello", "こんにちは"]))
        XCTAssertFalse(PasteSurface.containsJapanese(["Hello world", "🙂"]))
    }
}
