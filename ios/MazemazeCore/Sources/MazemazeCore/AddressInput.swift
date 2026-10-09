import Foundation

/// What the address bar text means. Anything that is not clearly a web address becomes a search,
/// and a search is the only thing that sends the typed words to an outside service.
public enum AddressInput: Equatable {
    case url(URL)
    case search(String)
    case rejected

    public static let searchHost = "duckduckgo.com"
    public static let searchServiceName = "DuckDuckGo"

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

    /// https://duckduckgo.com/?q=<words>, with the words percent-encoded.
    public static func searchURL(for words: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"; c.host = searchHost; c.path = "/"
        c.queryItems = [URLQueryItem(name: "q", value: words)]
        return c.url
    }
}
