import XCTest
import JavaScriptCore
@testable import MazemazeCore

final class BrowserIdentityTests: XCTestCase {
    func testOnlyXHostsGetTheSafariStyleIdentity() {
        for h in ["x.com", "X.com", "www.x.com", "mobile.twitter.com", "twitter.com", "x.com."] { XCTAssertTrue(BrowserIdentity.wantsSafariIdentity(host: h), h) }
        for h in ["news.yahoo.co.jp", "notx.com", "x.com.evil.example", "t.co", "example.com", ""] { XCTAssertFalse(BrowserIdentity.wantsSafariIdentity(host: h), h) }
        XCTAssertFalse(BrowserIdentity.wantsSafariIdentity(host: nil))
    }

    func testSafariStyleAddsOnlyTheStandardTokens() {
        let base = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        XCTAssertEqual(BrowserIdentity.safariStyle(from: base, osMajor: 26, osMinor: 1),
                       "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1")
        let already = base + " Version/26.1 Safari/604.1"
        XCTAssertEqual(BrowserIdentity.safariStyle(from: already, osMajor: 26, osMinor: 1), already)
        XCTAssertEqual(BrowserIdentity.safariStyle(from: "", osMajor: 26, osMinor: 1), "")
    }

    /// Runs the page script in a bare JS engine with a fake window / location.
    private func run(host: String, preset: [String] = []) -> (schema: Bool, microdata: Bool) {
        let ctx = JSContext()!
        ctx.evaluateScript("var window = this; var location = { hostname: \"\(host)\" };")
        for n in preset { ctx.evaluateScript("window[\"\(n)\"] = 1;") }
        ctx.evaluateScript(BrowserIdentity.xPageScript)
        XCTAssertNil(ctx.exception?.toString())
        return (ctx.evaluateScript("'SchemaDataExtractor' in window").toBool(), ctx.evaluateScript("'MicrodataExtractor' in window").toBool())
    }

    func testPageScriptDefinesThePlaceholdersOnXOnly() {
        for h in ["x.com", "www.x.com", "twitter.com", "mobile.twitter.com"] {
            let r = run(host: h); XCTAssertTrue(r.schema && r.microdata, h)
        }
        for h in ["news.yahoo.co.jp", "notx.com", "x.com.evil.example", "example.com", "t.co", ""] {
            let r = run(host: h); XCTAssertFalse(r.schema || r.microdata, h)
        }
    }

    func testPageScriptDoesNotReplaceAnExistingObject() {
        let ctx = JSContext()!
        ctx.evaluateScript("var window = this; var location = { hostname: 'x.com' }; window.SchemaDataExtractor = { real: true };")
        ctx.evaluateScript(BrowserIdentity.xPageScript)
        XCTAssertTrue(ctx.evaluateScript("window.SchemaDataExtractor.real === true").toBool())
    }
}
