import Foundation

/// What the address bar text means. Anything that is not clearly a web address becomes a search,
/// and a search is the only thing that sends the typed words to an outside service.
public enum AddressInput: Equatable {
    case url(URL)
    case search(String)
    case rejected

    public static func classify(_ raw: String) -> AddressInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return .rejected }
        if let colon = text.firstIndex(of: ":"), text[text.startIndex..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
           !text[text.startIndex..<colon].isEmpty {
            let scheme = text[text.startIndex..<colon].lowercased()
            let afterColon = text[text.index(after: colon)...]
            // "example.com:8080" is a host with a port, not a scheme.
            let looksLikePort = text[text.startIndex..<colon].contains(".") && afterColon.first?.isNumber == true
            if !looksLikePort {
                guard scheme == "http" || scheme == "https", afterColon.hasPrefix("//"),
                      !text.contains(" "), let url = URL(string: text), url.host?.isEmpty == false else { return .rejected }
                return .url(url)
            }
        }
        // A bare "host.tld" (ASCII only: Japanese words with a dot, like "3.5度", are searches, not addresses).
        let hostPart = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if !text.contains(" "), text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), hostPart.unicodeScalars.allSatisfy({ $0.isASCII }),
           let url = URL(string: "https://" + text), url.host?.isEmpty == false { return .url(url) }
        return .search(text)
    }

    /// The results page of `engine` for these words (percent-encoded). Google by default.
    public static func searchURL(for words: String, engine: SearchEngine = .google) -> URL? {
        var c = URLComponents()
        c.scheme = "https"; c.host = engine.host; c.path = engine.path
        c.queryItems = [URLQueryItem(name: engine.queryName, value: words)]
        return c.url
    }
}

/// Where the words typed in the address bar are searched. The words go to the chosen service (the page text never does).
public enum SearchEngine: String, CaseIterable, Equatable, Sendable {
    case google, yahooJapan, bing, duckDuckGo

    public var title: String {
        switch self {
        case .google: return "Google"
        case .yahooJapan: return "Yahoo! JAPAN"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        }
    }
    public var host: String {
        switch self {
        case .google: return "www.google.com"
        case .yahooJapan: return "search.yahoo.co.jp"
        case .bing: return "www.bing.com"
        case .duckDuckGo: return "duckduckgo.com"
        }
    }
    public var path: String {
        switch self {
        case .google, .yahooJapan, .bing: return "/search"
        case .duckDuckGo: return "/"
        }
    }
    public var queryName: String { self == .yahooJapan ? "p" : "q" }
}
