import Foundation
import CryptoKit

/// A candidate / chosen piece of the page text. `start`/`end` are Unicode scalar offsets (like Python's).
public struct SelectedSpan: Equatable, Sendable {
    public let id: String
    public let start: Int
    public let end: Int
    public let source: String
    public init(id: String, start: Int, end: Int, source: String) { self.id = id; self.start = start; self.end = end; self.source = source }
}

public struct SpanSelection: Equatable, Sendable {
    public let spans: [SelectedSpan]
    public let candidates: Int
    public let targetRatio: Double
    public let actualRatio: Double
}

public enum SpanError: Error, Equatable { case invalid(String) }

/// App-side span selection (port of backend/selector.py). The model never decides what to replace
/// (CLAUDE.md §5): candidates are whole clauses or sentences cut at Japanese punctuation, so particles and
/// conjugations stay intact. The choice is deterministic for the same text and settings.
public enum SpanSelector {
    public static let minRatio = 0.10, maxRatio = 0.70
    static let minCandidateChars = 4

    static func maxChars(_ unit: TranslationUnit) -> Int { unit == .phrase ? 60 : 120 }

    static let sentenceEnd = PyText.set("。！？!?｡")
    static let clauseEnd = PyText.set("、，,")
    static let closers = PyText.set("」』）)】］｝}〉》”’\"'")
    static let openers = PyText.set("「『（(【［｛{〈《“‘")
    static let newlines = PyText.set("\r\n\u{0B}\u{0C}\u{85}\u{2028}\u{2029}")
    static let junk: Set<UInt32> = sentenceEnd.union(clauseEnd).union(closers).union(openers).union(PyText.set(" \t\u{3000}"))
    /// Characters that do not count toward the ratio (Python `\s` plus the punctuation list in selector.py).
    static let ignoredForRatio = PyText.set("。、，．,.！!？?：:；;「」『』（）()【】［］｛｝{}〈〉《》“”‘’\"'…・―ー〜~-—/")

    /// ASCII-only on purpose: Japanese text next to a URL is not part of it.
    static let protected = try! NSRegularExpression(
        pattern: #"https?://|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.|[0-9０-９]|`|www\.|[A-Za-zＡ-Ｚａ-ｚ]"#, options: [.caseInsensitive])

    public static func countedLength(_ s: [Unicode.Scalar]) -> Int {
        s.reduce(0) { $0 + ((PyText.isSpace($1) || ignoredForRatio.contains($1.value)) ? 0 : 1) }
    }
    public static func countedLength(_ s: String) -> Int { countedLength(Array(s.unicodeScalars)) }

    static func trim(_ t: [Unicode.Scalar], _ start: Int, _ end: Int) -> (Int, Int) {
        var a = start, b = end
        while a < b, junk.contains(t[a].value) { a += 1 }
        while b > a, junk.contains(t[b - 1].value) { b -= 1 }
        return (a, b)
    }

    static func chunks(_ t: [Unicode.Scalar], _ unit: TranslationUnit) -> [(Int, Int)] {
        let enders = unit == .sentence ? sentenceEnd : sentenceEnd.union(clauseEnd)
        var out: [(Int, Int)] = []
        var start = 0, i = 0
        let n = t.count
        while i < n {
            let ch = t[i].value
            if newlines.contains(ch) {
                out.append((start, i)); start = i + 1
            } else if enders.contains(ch) {
                var end = i + 1
                while end < n, closers.contains(t[end].value) { end += 1 }
                out.append((start, end))
                start = end; i = end
                continue
            }
            i += 1
        }
        out.append((start, n))
        return out
    }

    static func joinsNeighbour(_ s: Unicode.Scalar) -> Bool {
        PyText.isMark(s) || s.value == 0x200D || s.value == 0xFE0E || s.value == 0xFE0F
    }

    static func hasProtected(_ s: String) -> Bool {
        protected.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func candidates(_ t: [Unicode.Scalar], unit: TranslationUnit) -> [SelectedSpan] {
        var out: [SelectedSpan] = []
        let limit = maxChars(unit)
        for (rawStart, rawEnd) in chunks(t, unit) {
            let (start, end) = trim(t, rawStart, rawEnd)
            if end <= start { continue }
            if joinsNeighbour(t[start]) || (end < t.count && joinsNeighbour(t[end])) { continue }   // would split a combining sequence
            let piece = Array(t[start..<end])
            if piece.count > limit || countedLength(piece) < minCandidateChars { continue }
            let pieceString = PyText.string(piece)
            if hasProtected(pieceString) { continue }
            // Unbalanced brackets would cut a quotation in half.
            let opens = piece.filter { openers.contains($0.value) }.count
            let closes = piece.filter { closers.contains($0.value) }.count
            if opens != closes, piece.contains(where: { openers.contains($0.value) || closers.contains($0.value) }) { continue }
            out.append(SelectedSpan(id: "s\(out.count + 1)", start: start, end: end, source: pieceString))
        }
        return out
    }

    static func rank(seed: Int, _ span: SelectedSpan) -> String {
        SHA256.hash(data: Data("\(seed)|\(span.start)|\(span.source)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Pick non-overlapping spans until their length reaches `ratio` of the text (a target, not a guarantee).
    /// Ids are renumbered in text order after selection.
    public static func select(text: String, ratio: Double, unit: TranslationUnit, seed: Int = 0, maxSpans: Int? = nil) throws -> SpanSelection {
        guard minRatio <= ratio, ratio <= maxRatio else { throw SpanError.invalid("ratio out of range") }
        let t = Array(text.unicodeScalars)
        let total = countedLength(t)
        let cands = candidates(t, unit: unit)
        if total == 0 || cands.isEmpty { return SpanSelection(spans: [], candidates: cands.count, targetRatio: ratio, actualRatio: 0) }

        let target = ratio * Double(total)
        var chosen: [SelectedSpan] = []
        var got = 0
        let ranked = cands.map { ($0, rank(seed: seed, $0)) }.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset      // stable, like Python's sorted
        }.map { $0.element.0 }
        for span in ranked {
            if Double(got) >= target || (maxSpans.map { chosen.count >= $0 } ?? false) { break }
            let length = countedLength(span.source)
            // Stop short of overshooting by more than half a candidate (keeps results near the target).
            if got > 0, Double(got + length) - target > Double(length) / 2 { continue }
            chosen.append(span)
            got += length
        }
        let ordered = chosen.sorted { $0.start < $1.start }
        let spans = ordered.enumerated().map { SelectedSpan(id: "s\($0.offset + 1)", start: $0.element.start, end: $0.element.end, source: $0.element.source) }
        try SpanRules.check(t, spans)
        return SpanSelection(spans: spans, candidates: cands.count, targetRatio: ratio, actualRatio: Double(got) / Double(total))
    }
}
