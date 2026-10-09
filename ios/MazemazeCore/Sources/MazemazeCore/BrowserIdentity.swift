import Foundation

/// 2026-10-09, decided by the owner (personal use, X only): the in-app browser presents itself to X as Safari.
/// What is done, exactly:
///  1. the user agent gets Safari's standard "Version/x … Safari/y" tokens (a bare WKWebView leaves them out);
///  2. at document start on x.com / twitter.com, two inert placeholder objects that Safari itself exposes
///     (`SchemaDataExtractor`, `MicrodataExtractor`) are defined, because X's page script treats a "Safari"
///     without them as a fake and sends it to the real Safari (found by reading X's public entry script and
///     confirmed in the simulator: the UA alone was not enough).
/// Nothing else is faked: no other app's name, no query parameters that skip X's checks, nothing on other sites,
/// no login/cookie handling, no automation. If X still redirects, the "Safari で開く" card is shown as before.
public enum BrowserIdentity {
    /// Hosts that get the Safari-style identity: x.com / twitter.com and their subdomains.
    public static func wantsSafariIdentity(host: String?) -> Bool {
        guard var h = host?.lowercased() else { return false }
        if h.hasSuffix(".") { h.removeLast() }
        return ["x.com", "twitter.com"].contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The web view's own user agent with Safari's tokens added ("… Version/26.1 Mobile/15E148 Safari/604.1").
    /// A user agent that already has them is returned unchanged.
    public static func safariStyle(from webViewUA: String, osMajor: Int, osMinor: Int) -> String {
        guard !webViewUA.isEmpty, !webViewUA.contains("Safari/") else { return webViewUA }
        var ua = webViewUA
        if !ua.contains("Version/"), let r = ua.range(of: " Mobile/") { ua.replaceSubrange(r, with: " Version/\(osMajor).\(osMinor) Mobile/") }
        return ua + " Safari/604.1"
    }

    /// Page-world script (document start, main frame). It only acts on x.com / twitter.com (checked inside, so a
    /// web view that later moves to another site is untouched) and only adds the missing names; it changes nothing else.
    public static let xPageScript = """
    (function () {
      try {
        var h = String(location.hostname || "").toLowerCase();
        if (!/^(?:[a-z0-9-]+\\.)*(?:x|twitter)\\.com$/.test(h)) { return; }
        ["SchemaDataExtractor", "MicrodataExtractor"].forEach(function (name) {
          if (!(name in window)) {
            Object.defineProperty(window, name, { value: Object.freeze({}), writable: false, configurable: true, enumerable: false });
          }
        });
      } catch (e) { /* never break the page */ }
    })();
    """
}
