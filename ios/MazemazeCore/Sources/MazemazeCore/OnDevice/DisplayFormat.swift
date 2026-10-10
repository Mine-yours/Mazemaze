import Foundation

/// Display formatting for accepted English spans (port of backend/display.py). Only the `display` string of English
/// segments is touched, and only its first letter and its final period; anything uncertain is left as written.
public enum DisplayFormat {
    static let lowerable: Set<String> = [
        "the", "a", "an", "he", "she", "they", "we", "it", "this", "that", "these", "those",
        "there", "here", "my", "your", "his", "her", "our", "their", "its", "and", "but", "so",
        "then", "if", "when", "while", "because", "since", "as", "after", "before", "although",
        "though", "unless", "until", "once", "also", "just", "even", "still", "yet", "now",
        "what", "why", "how", "who", "where", "which", "let", "do", "does", "did", "is", "are",
        "was", "were", "can", "could", "should", "would", "to", "for", "in", "on", "at", "with",
        "from", "by", "of", "about", "without", "into", "over", "under", "every", "each", "all",
        "some", "any", "no", "not", "maybe", "perhaps",
    ]
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "inc", "ltd", "co", "no",
        "approx", "dept", "est", "fig", "vol", "e.g", "i.e", "a.m", "p.m", "u.s", "u.k",
    ]
    static let sentenceStartPrev = PyText.set("。！？!?｡「『（([“\"‘'〈《【［｛{<\n\r\t \u{3000}")
    static let closers = PyText.set("」』）)】］｝}〉》”’\"'")
    static let splitters = PyText.set("(\"'“‘")

    public struct Segment: Equatable, Sendable {
        public let kind: SpanRules.Kind
        public let text: String
        public let display: String
        public let source: String
        public let start: Int
        public let end: Int
    }

    static func ascii(_ s: Unicode.Scalar) -> Bool { (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A) }

    static func stripFinalPeriod(_ en: [Unicode.Scalar], next: Unicode.Scalar?) -> [Unicode.Scalar] {
        guard let next, !PyText.isSpace(next), en.last == "." else { return en }
        if en.count >= 2, en[en.count - 2] == "." { return en }       // ".."
        if en.last == "\u{2026}" { return en }
        let body = Array(en.dropLast())
        guard let last = body.last, PyText.isAlpha(last) else { return en }       // "3.", "?." and similar stay as they are
        var tokenStart = body.count
        while tokenStart > 0, !(PyText.isSpace(body[tokenStart - 1]) || splitters.contains(body[tokenStart - 1].value)) { tokenStart -= 1 }
        let lastWord = Array(body[tokenStart...])
        if lastWord.contains(".") { return en }                        // U.S., e.g, Ph.D, www.example
        if lastWord.count == 1, PyText.isUpper(lastWord[0]) { return en }   // initials: "J."
        if abbreviations.contains(PyText.string(lastWord).lowercased()) { return en }
        return body
    }

    static func lowerFirstLetter(_ en: [Unicode.Scalar], prev: Unicode.Scalar?) -> [Unicode.Scalar] {
        if prev == nil || sentenceStartPrev.contains(prev!.value) { return en }
        // _FIRST_WORD = [A-Za-z]+(?=\s|$|[,;:]) matched at the start
        var n = 0
        while n < en.count, ascii(en[n]) { n += 1 }
        guard n > 0 else { return en }
        if n < en.count {
            let f = en[n]
            guard PyText.isSpace(f) || f == "," || f == ";" || f == ":" else { return en }
        }
        // rest[0][0].isupper(): the first character of the next whitespace-separated word
        var i = n
        while i < en.count, PyText.isSpace(en[i]) { i += 1 }
        if i < en.count, PyText.isUpper(en[i]) { return en }                  // "The Beatles", "A Clockwork Orange": a title or name
        let word = Array(en[0..<n])
        let restLower = word.dropFirst().allSatisfy { $0.value >= 0x61 && $0.value <= 0x7A }
        guard word[0].value >= 0x41 && word[0].value <= 0x5A, (word.count == 1 || (restLower && word.count > 1)), lowerable.contains(PyText.string(word).lowercased()) else { return en }
        var out = en
        out[0] = Unicode.Scalar(word[0].value + 32)!
        return out
    }

    public static func format(_ en: String, prev: Unicode.Scalar?, next: Unicode.Scalar?) -> String {
        let e = Array(en.unicodeScalars)
        let out = PyText.string(lowerFirstLetter(stripFinalPeriod(e, next: next), prev: prev))
        // Safety net: only the first letter's case and one final "." may differ.
        let lowered = out.lowercased()
        if out.isEmpty || !(lowered == en.lowercased() || lowered == PyText.string(e.dropLast()).lowercased()) { return en }
        return out
    }

    /// The character before `start`; looks through closing quotes/brackets to a sentence end.
    public static func previousChar(_ t: [Unicode.Scalar], _ start: Int) -> Unicode.Scalar? {
        if start <= 0 { return nil }
        var i = start - 1
        while i > 0, closers.contains(t[i].value) { i -= 1 }
        if sentenceEndMarks.contains(t[i].value) { return t[i] }
        return t[start - 1]
    }
    static let sentenceEndMarks = PyText.set("。！？!?｡")

    public static func segments(_ t: [Unicode.Scalar], _ segs: [SpanRules.Segment]) -> [Segment] {
        segs.map { seg in
            if seg.kind == .en {
                let display = format(seg.text, prev: previousChar(t, seg.start), next: seg.end < t.count ? t[seg.end] : nil)
                return Segment(kind: .en, text: seg.text, display: display, source: seg.source, start: seg.start, end: seg.end)
            }
            return Segment(kind: .ja, text: seg.text, display: seg.text, source: seg.source, start: seg.start, end: seg.end)
        }
    }

    /// True when every Japanese segment is the exact original slice and coverage is contiguous.
    public static func outsidePreserved(_ t: [Unicode.Scalar], _ segs: [Segment]) -> Bool {
        var pos = 0
        for s in segs {
            if s.start != pos || s.end > t.count || PyText.string(t[s.start..<s.end]) != s.source { return false }
            if s.kind == .ja && !(s.text == s.source && s.source == s.display) { return false }
            pos = s.end
        }
        return pos == t.count
    }
}
