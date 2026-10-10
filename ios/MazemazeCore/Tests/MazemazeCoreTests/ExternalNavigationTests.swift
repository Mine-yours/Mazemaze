import XCTest
@testable import MazemazeCore

final class ExternalNavigationTests: XCTestCase {
    func c(_ s: String) -> ExternalNavigation { URL(string: s).map(ExternalNavigation.classify) ?? .blocked }

    func testWebAndBlank() {
        XCTAssertEqual(c("https://news.yahoo.co.jp/articles/a"), .allowInApp)
        XCTAssertEqual(c("http://localhost:8080/x"), .allowInApp)
        XCTAssertEqual(c("about:blank"), .allowInApp)
        XCTAssertEqual(c("about:srcdoc"), .blocked)
    }

    func testSafariRedirectIsRecognizedNotFollowed() {
        XCTAssertEqual(c("x-safari-https://redirect.x.com/nhk_news?ct=rw-null"),
                       .safariRedirect(URL(string: "https://redirect.x.com/nhk_news?ct=rw-null")!))
        XCTAssertEqual(c("X-SAFARI-HTTPS://redirect.x.com/a"), .safariRedirect(URL(string: "https://redirect.x.com/a")!))
        XCTAssertEqual(c("x-safari-http://example.com/a"), .safariRedirect(URL(string: "http://example.com/a")!))
        XCTAssertEqual(c("x-safari-https:///nohost"), .blocked)
    }

    func testDangerousSchemesAreBlocked() {
        for s in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "blob:https://a.com/uuid", "ftp://a.com/", "view-source:https://a.com", "ws://a.com/"] {
            XCTAssertEqual(c(s), .blocked, s)
        }
    }

    func testOnlyPhoneMailSmsMapsMayOpenOutside() {
        for s in ["tel:0312345678", "mailto:a@b.com", "sms:0312345678", "facetime:a@b.com", "maps://?q=tokyo"] {
            if case .external = c(s) {} else { XCTFail(s) }
        }
        for s in ["line://msg/text/hi", "itms-apps://apps.apple.com/app/id1", "itms-services://?action=download-manifest&url=https://a.com/m.plist",
                  "yahoojapan://x", "1abc://x", "twitter://timeline"] {
            XCTAssertEqual(c(s), .blocked, s)
        }
    }
}
