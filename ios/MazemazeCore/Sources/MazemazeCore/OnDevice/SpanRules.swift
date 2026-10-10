import Foundation

/// Span checks, translation validation and assembly (port of backend/spans.py). Offsets are Unicode scalars.
/// Text is never normalized. Anything that fails validation stays Japanese, so the original text is always
/// reconstructible.
public enum SpanRules {
    public static func check(_ t: [Unicode.Scalar], _ spans: [SelectedSpan]) throws {
        var seen = Set<String>()
        for s in spans {
            guard seen.insert(s.id).inserted else { throw SpanError.invalid("\(s.id): duplicate id") }
            guard s.start < s.end else { throw SpanError.invalid("\(s.id): empty span") }
            guard s.start >= 0, s.end <= t.count else { throw SpanError.invalid("\(s.id): out of range") }
            guard PyText.string(t[s.start..<s.end]) == s.source else { throw SpanError.invalid("\(s.id): source does not match text") }
            guard !s.source.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw SpanError.invalid("\(s.id): span contains a newline") }
            guard !PyText.isCombining(t[s.start]) else { throw SpanError.invalid("\(s.id): span starts with a combining character") }
            if s.end < t.count, PyText.isCombining(t[s.end]) { throw SpanError.invalid("\(s.id): span splits a combining sequence") }
        }
        let ordered = spans.sorted { $0.start < $1.start }
        for (a, b) in zip(ordered, ordered.dropFirst()) where b.start < a.end { throw SpanError.invalid("\(a.id)/\(b.id): overlapping spans") }
    }

    // ASCII-only on purpose (see the Python source): Japanese next to a URL is not part of it.
    static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    static let url = rx(#"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#)
    static let email = rx(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    static let number = rx(#"[0-9][0-9,.]*"#)
    static let code = rx(#"`([^`\n]{3,})`"#)
    static let numericToken = rx(#"^[0-9][0-9,.]*$"#)
    static let blankRun = rx(#"_{3,}"#)
    static let preamble = rx(#"^(?:here(?:'s|\s+is|\s+are)\s+(?:the|my|your|an?)?\s*(?:english\s+)?translations?\b|(?:sure|certainly|of\s+course)[,!:]\s*(?:here|this\s+is|the\s+translation|translation)\b|(?:english\s+)?translation\s*:|english\s*:)"#, [.caseInsensitive])
    static let placeholders: [(Character, NSRegularExpression)] = [
        ("[", rx(#"\[[^\[\]]{1,60}\]"#)), ("{", rx(#"\{[^{}]{0,60}\}"#)), ("<", rx(#"<[^<>]{1,60}>"#)),
    ]
    static let japaneseRanges: [ClosedRange<UInt32>] = [0x3040...0x309F, 0x30A0...0x30FF, 0xFF66...0xFF9F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x3134F]
    static let bidi: Set<UInt32> = Set(0x202A...0x202E).union(0x2066...0x2069)

    static func matches(_ r: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        return r.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    static func test(_ r: NSRegularExpression, _ s: String, anchored: Bool = false) -> Bool {
        r.firstMatch(in: s, options: anchored ? [.anchored] : [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    public static func normalize(_ en: String) -> String { PyText.string(PyText.strip(Array(en.unicodeScalars))) }

    public static func looksLikePreamble(_ en: String) -> Bool {
        let s = normalize(en)
        return s.contains("```") || test(preamble, s, anchored: true)
    }

    static func trimToken(_ token: String) -> String {
        var v = Array(token.unicodeScalars)
        let tail = PyText.set(".,;:!?)]'\"")
        while let last = v.last, tail.contains(last.value) { v.removeLast() }
        return PyText.string(v)
    }

    static func protectedTokens(_ source: String) -> [String] {
        var tokens: [String] = []
        for r in [url, email, number] { tokens += matches(r, source).map(trimToken).filter { !$0.isEmpty } }
        return tokens
    }

    static func containsToken(_ en: String, _ token: String) -> Bool {
        if test(numericToken, token) {
            // Whole number only: "15" is not inside "2015" or "15.5", but may touch letters ("3D", "1990s", "page2").
            let p = "(?<![0-9])(?<![0-9][.,])" + NSRegularExpression.escapedPattern(for: token) + "(?![0-9])(?![.,][0-9])"
            return test(rx(p), en)
        }
        return en.unicodeScalars.count >= token.unicodeScalars.count && Array(en.unicodeScalars).containsSubsequence(Array(token.unicodeScalars))
    }

    /// Everything except the span, used to detect content copied in from the context.
    public static func outsideText(_ t: [Unicode.Scalar], _ span: SelectedSpan) -> String {
        PyText.string(t[..<span.start]) + "\n" + PyText.string(t[span.end...])
    }

    static func contextTokens(_ outside: String, _ source: String) -> [String] {
        var tokens = protectedTokens(outside)
        let ns = outside as NSString
        for m in code.matches(in: outside, options: [], range: NSRange(location: 0, length: ns.length)) {
            tokens.append(PyText.string(PyText.strip(Array(ns.substring(with: m.range(at: 1)).unicodeScalars))))
        }
        return tokens.filter { !$0.isEmpty && !source.contains($0) }
    }

    static func hasPlaceholder(_ source: String, _ en: String) -> Bool {
        if !en.unicodeScalars.contains(where: PyText.isAlnum) || test(blankRun, en) { return true }
        return placeholders.contains { !source.contains($0.0) && test($0.1, en) }
    }

    /// nil if acceptable, otherwise a reason code (same codes as the server).
    public static func validate(source: String, en rawEn: String, outside: String) -> String? {
        let en = normalize(rawEn)
        if en.isEmpty { return "empty" }
        let scalars = Array(en.unicodeScalars)
        if scalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return "newline" }
        for ch in scalars {
            switch PyText.category(ch) {
            case .control, .surrogate, .lineSeparator, .paragraphSeparator: return "control_char"
            case .format where ch.value != 0x200D: return "control_char"
            default: if bidi.contains(ch.value) { return "control_char" }
            }
        }
        if scalars.contains(where: { c in japaneseRanges.contains { $0.contains(c.value) } }) { return "japanese_chars" }
        if scalars.count > max(8 * source.unicodeScalars.count, 100) { return "too_long" }
        if looksLikePreamble(en) { return "preamble" }
        if hasPlaceholder(source, en) { return "placeholder" }
        for token in protectedTokens(source) where !containsToken(en, token) { return "protected_token_missing" }
        if contextTokens(outside, source).contains(where: { containsToken(en, $0) }) { return "context_leak" }
        return nil
    }

    public enum Kind: String, Sendable { case ja, en }
    public struct Segment: Equatable, Sendable {
        public let kind: Kind
        public let text: String
        public let source: String
        public let start: Int
        public let end: Int
    }

    public static func assemble(_ t: [Unicode.Scalar], _ spans: [SelectedSpan], _ translations: [String: String]) throws -> [Segment] {
        try check(t, spans)
        var segments: [Segment] = []
        var pos = 0
        func addJa(_ a: Int, _ b: Int) {
            if b > a { let chunk = PyText.string(t[a..<b]); segments.append(Segment(kind: .ja, text: chunk, source: chunk, start: a, end: b)) }
        }
        for s in spans.sorted(by: { $0.start < $1.start }) {
            addJa(pos, s.start)
            if let raw = translations[s.id] {
                let en = normalize(raw)
                if validate(source: s.source, en: en, outside: outsideText(t, s)) == nil {
                    segments.append(Segment(kind: .en, text: en, source: s.source, start: s.start, end: s.end))
                } else { addJa(s.start, s.end) }
            } else { addJa(s.start, s.end) }
            pos = s.end
        }
        addJa(pos, t.count)
        guard isPreserved(t, segments) else { throw SpanError.invalid("original text not preserved") }
        return segments
    }

    public static func isPreserved(_ t: [Unicode.Scalar], _ segments: [Segment]) -> Bool {
        var pos = 0
        for s in segments {
            if s.start != pos || s.end > t.count || PyText.string(t[s.start..<s.end]) != s.source { return false }
            if s.kind == .ja && s.text != s.source { return false }
            pos = s.end
        }
        return pos == t.count
    }
}

extension Array where Element == Unicode.Scalar {
    func containsSubsequence(_ needle: [Unicode.Scalar]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > count { return false }
        for i in 0...(count - needle.count) where self[i] == needle[0] && Array(self[i..<(i + needle.count)]) == needle { return true }
        return false
    }
}
