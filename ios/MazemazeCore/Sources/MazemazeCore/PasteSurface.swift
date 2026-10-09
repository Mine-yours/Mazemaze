import Foundation

/// "貼り付けて翻訳": text the person copied (from Safari, the X app, ...) is shown on an app-owned page
/// and goes through the same translation pipeline as a web page. That page has a fixed, never-resolvable
/// address; only the app itself may load it, and nothing about it is ever stored.
public enum PasteSurface {
    /// `.invalid` can never be resolved (RFC 6761), so this address cannot reach a real server.
    public static let host = "paste.mazemaze.invalid"
    public static let url = URL(string: "https://paste.mazemaze.invalid/")!
    /// Characters accepted per paste. Long enough for a post or an article section, short enough to finish in a minute or two.
    public static let maxCharacters = 4000

    /// Exactly the app's own page: https, this host, no port / user / query / fragment, root path.
    public static func isPasteURL(_ url: URL?) -> Bool {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme?.lowercased() == "https" && c.host?.lowercased() == host && c.port == nil
            && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
            && (c.percentEncodedPath.isEmpty || c.percentEncodedPath == "/")
    }

    /// Any address on or under the host (a normal tab must never navigate there).
    public static func touchesPasteHost(_ url: URL?) -> Bool {
        guard var h = url?.host?.lowercased() else { return false }
        if h.hasSuffix(".") { h.removeLast() }
        return h == host || h.hasSuffix("." + host)
    }

    public enum InputError: Error, Equatable, Sendable {
        case empty
        case tooLong(Int)
        public var message: String {
            switch self {
            case .empty: return "文章を貼り付けてください。"
            case .tooLong(let n): return "長すぎます（\(n) 文字）。\(PasteSurface.maxCharacters) 文字以内に分けて貼り付けてください。"
            }
        }
    }

    /// The text to translate, as lines. CRLF / CR become LF, NUL characters are dropped, and blank lines at the
    /// very start / end are removed. Everything else (spaces, blank lines inside, emoji) is kept exactly:
    /// `lines.joined(separator: "\n")` is the "original" the result can always be restored to.
    public static func normalize(_ raw: String) -> Result<[String], InputError> {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s.removeAll { $0 == "\u{0}" }
        var lines = s.components(separatedBy: "\n")
        while let f = lines.first, f.allSatisfy({ $0.isWhitespace }) { lines.removeFirst() }
        while let l = lines.last, l.allSatisfy({ $0.isWhitespace }) { lines.removeLast() }
        guard !lines.isEmpty else { return .failure(.empty) }
        let count = lines.reduce(0) { $0 + $1.count } + (lines.count - 1)
        guard count <= maxCharacters else { return .failure(.tooLong(count)) }
        return .success(lines)
    }

    /// True if the text has enough Japanese to be worth translating (a hint shown to the person, not a block).
    public static func containsJapanese(_ lines: [String]) -> Bool {
        lines.contains { $0.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) } }
    }
}
