import Foundation

/// How a main-frame navigation target is treated by the in-app browser.
public enum ExternalNavigation: Equatable, Sendable {
    /// Ordinary web page (or about:blank): load it here.
    case allowInApp
    /// The site bounced us to "x-safari-https://…": it refuses in-app browsers and wants Safari.
    /// Carries the https URL it asked for. We do not work around this (no User-Agent changes).
    case safariRedirect(URL)
    /// A phone / mail / SMS / maps link. Only opened after the user taps the prompt.
    case external(URL)
    /// Never followed: javascript:, file:, data:, blob:, view-source:, …
    case blocked

    public static func classify(_ url: URL) -> ExternalNavigation {
        guard let scheme = url.scheme?.lowercased() else { return .blocked }
        switch scheme {
        case "http", "https":
            return .allowInApp
        case "about":
            return url.absoluteString == "about:blank" ? .allowInApp : .blocked
        case "x-safari-https", "x-safari-http":
            let real = scheme == "x-safari-https" ? "https" : "http"
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = real
            if let u = comps?.url, let host = u.host, !host.isEmpty { return .safariRedirect(u) }
            return .blocked
        case "javascript", "file", "data", "blob", "ftp", "view-source", "filesystem", "ws", "wss":
            return .blocked
        case "tel", "mailto", "sms", "facetime", "facetime-audio", "maps":
            return .external(url)       // the only schemes a page may hand to another app (after a tap)
        default:
            return .blocked             // app-install schemes (itms-services …) and unknown schemes never open
        }
    }
}
