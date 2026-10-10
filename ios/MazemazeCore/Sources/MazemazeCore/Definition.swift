import Foundation

/// What the person wants to look up: one word of the English that is on the page, or the whole phrase.
public enum LookupKind: String, Codable, Equatable, Sendable { case word, phrase }

public struct LookupRequest: Equatable, Sendable, Identifiable {
    public static let maxWordScalars = 40
    public static let maxPhraseScalars = 300
    public static let maxContextScalars = 600

    public let kind: LookupKind
    public let term: String
    /// The English phrase the word sits in (context for a word), and the Japanese it replaced (the original).
    public let contextEnglish: String
    public let contextJapanese: String
    public var id: String { "\(kind.rawValue)|\(term.lowercased())|\(contextEnglish)|\(contextJapanese)" }

    /// nil when the request is not usable (empty, a "word" that is several words, too long, control characters).
    public static func make(kind: LookupKind, term: String, contextEnglish: String, contextJapanese: String) -> LookupRequest? {
        let t = DefinitionText.line(term)
        guard !t.isEmpty else { return nil }
        switch kind {
        case .word:
            guard t.unicodeScalars.count <= maxWordScalars, !t.contains(where: { $0.isWhitespace }), t.contains(where: { $0.isLetter }) else { return nil }
        case .phrase:
            guard t.unicodeScalars.count <= maxPhraseScalars else { return nil }
        }
        func ctx(_ s: String) -> String { String(String.UnicodeScalarView(DefinitionText.line(s).unicodeScalars.prefix(maxContextScalars))) }
        return LookupRequest(kind: kind, term: t, contextEnglish: ctx(contextEnglish), contextJapanese: ctx(contextJapanese))
    }

    private init(kind: LookupKind, term: String, contextEnglish: String, contextJapanese: String) {
        self.kind = kind; self.term = term; self.contextEnglish = contextEnglish; self.contextJapanese = contextJapanese
    }
}

/// The words of an English phrase, in order, without repeats (the choices offered in the lookup sheet).
public enum EnglishWords {
    public static func words(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z]+(?:['’-][A-Za-z]+)*") else { return [] }
        let ns = text as NSString
        var seen = Set<String>(), out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            if seen.insert(w.lowercased()).inserted { out.append(w) }
        }
        return out
    }
}

public struct WordMeaning: Codable, Equatable, Sendable {
    public var meaning: String
    public var exampleEn: String?
    public var exampleJa: String?
}

public struct WordCard: Codable, Equatable, Sendable {
    public var lemma: String
    public var pos: String
    /// The sense that fits the sentence the word was read in, and where it is in `meanings`.
    public var contextMeaning: String
    public var contextIndex: Int
    public var meanings: [WordMeaning]
    /// The words of the Japanese original that this word corresponds to (only when they really are in it).
    public var matchInSource: String?
    public var phrases: [String]
    public var note: String?
    /// Which engine made the card ("mac" or "device"); nil for cards saved before this was recorded (they all came from the Mac).
    public var maker: String?
    /// True once "more" (an example, expressions, a remark) has been added.
    public var hasMore: Bool { phrases.contains { !$0.isEmpty } || note != nil || meanings.contains { $0.exampleEn != nil } }
}

public struct PhrasePoint: Codable, Equatable, Sendable { public var expr: String; public var note: String }
public struct PhraseExample: Codable, Equatable, Sendable { public var en: String; public var ja: String }

public struct PhraseCard: Codable, Equatable, Sendable {
    public var meaning: String
    public var nuance: String?
    public var points: [PhrasePoint]
    public var synonyms: [String]
    public var examples: [PhraseExample]
    public var maker: String?
    public var hasMore: Bool { !points.isEmpty || !synonyms.isEmpty || !examples.isEmpty }
}

/// The second step of a card (asked for on demand): an example, expressions and a remark / points and synonyms.
public enum DefinitionMore: Equatable, Sendable {
    case word(example: PhraseExample?, phrases: [String], note: String?)
    case phrase(points: [PhrasePoint], synonyms: [String], example: PhraseExample?)

    public static func decode(serverResponse data: Data) -> DefinitionMore? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = root["card"] as? [String: Any] else { return nil }
        func example(_ v: Any?) -> PhraseExample? {
            guard let e = v as? [String: Any], let en = DefinitionText.field(e["en"], limit: 120) else { return nil }
            return PhraseExample(en: en, ja: DefinitionText.field(e["ja"], limit: 120) ?? "")
        }
        switch d["kind"] as? String {
        case "word_more":
            let ex = example(d["example"]), phrases = DefinitionText.fields(d["phrases"], limit: 40, count: 4), note = DefinitionText.field(d["note"], limit: 80)
            guard ex != nil || !phrases.isEmpty || note != nil else { return nil }
            return .word(example: ex, phrases: phrases, note: note)
        case "phrase_more":
            var points: [PhrasePoint] = []
            for raw in (d["points"] as? [Any] ?? []) {
                guard let p = raw as? [String: Any], let e = DefinitionText.field(p["expr"], limit: 80) else { continue }
                points.append(PhrasePoint(expr: e, note: DefinitionText.field(p["note"], limit: 80) ?? ""))
                if points.count >= 2 { break }
            }
            let syn = DefinitionText.fields(d["synonyms"], limit: 60, count: 3), ex = example(d["example"])
            guard !points.isEmpty || !syn.isEmpty || ex != nil else { return nil }
            return .phrase(points: points, synonyms: syn, example: ex)
        default: return nil
        }
    }
}

/// A card made by the local model. It is always shown as AI-made, and every field is validated before use.
public enum DefinitionCard: Equatable, Sendable {
    case word(WordCard)
    case phrase(PhraseCard)

    public static let makerMac = "mac", makerDevice = "device"

    /// The card with the engine that made it recorded (shown in the explanation under the card).
    public func settingMaker(_ maker: String) -> DefinitionCard {
        switch self {
        case .word(var c): c.maker = maker; return .word(c)
        case .phrase(var c): c.maker = maker; return .phrase(c)
        }
    }

    public var maker: String? {
        switch self { case .word(let c): return c.maker; case .phrase(let c): return c.maker }
    }

    /// Who made the card, for the note under it. A card without a record was made before the iPhone could make them: by the Mac.
    public var makerName: String { maker == Self.makerDevice ? "iPhone の Apple Intelligence" : "Mac のローカルモデル" }

    /// One line for lists: the sense in context (word) or the meaning (phrase).
    public var headline: String {
        switch self { case .word(let c): return c.contextMeaning; case .phrase(let c): return c.meaning }
    }

    /// Everything on the card as searchable text.
    public var searchText: String {
        switch self {
        case .word(let c):
            return ([c.lemma, c.pos, c.contextMeaning, c.note ?? "", c.matchInSource ?? ""] + c.meanings.map(\.meaning) + c.phrases).joined(separator: " ")
        case .phrase(let c):
            return ([c.meaning, c.nuance ?? ""] + c.points.map(\.expr) + c.synonyms).joined(separator: " ")
        }
    }

    /// For the CSV: the senses (word) or the points (phrase) on one line.
    public var details: String {
        switch self {
        case .word(let c): return c.meanings.map(\.meaning).joined(separator: " / ")
        case .phrase(let c): return ([c.nuance ?? ""] + c.points.map { $0.note.isEmpty ? $0.expr : "\($0.expr): \($0.note)" }).filter { !$0.isEmpty }.joined(separator: " / ")
        }
    }

    /// The card with the second step added (a "more" that does not fit this kind of card changes nothing).
    public func merging(_ more: DefinitionMore) -> DefinitionCard {
        switch (self, more) {
        case (.word(var c), .word(let example, let phrases, let note)):
            if let example, c.meanings.indices.contains(c.contextIndex) {
                c.meanings[c.contextIndex].exampleEn = example.en
                c.meanings[c.contextIndex].exampleJa = example.ja.isEmpty ? nil : example.ja
            }
            c.phrases = phrases; c.note = note
            return .word(c)
        case (.phrase(var c), .phrase(let points, let synonyms, let example)):
            c.points = points; c.synonyms = synonyms; c.examples = example.map { [$0] } ?? []
            return .phrase(c)
        default: return self
        }
    }

    // MARK: decoding the server's answer (never trusted)
    /// `{"card": {...}}` as the server sends it; nil if anything essential is missing or malformed.
    public static func decode(serverResponse data: Data) -> DefinitionCard? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let card = root["card"] as? [String: Any] else { return nil }
        switch card["kind"] as? String {
        case "word": return word(card)
        case "phrase": return phrase(card)
        default: return nil
        }
    }

    private static func word(_ d: [String: Any]) -> DefinitionCard? {
        guard let lemma = DefinitionText.field(d["lemma"], limit: 40), isLemma(lemma),
              let meaning = DefinitionText.field(d["contextMeaning"], limit: 40) else { return nil }
        var meanings: [WordMeaning] = []
        for raw in (d["meanings"] as? [Any] ?? []) {
            guard let m = raw as? [String: Any], let mm = DefinitionText.field(m["meaning"], limit: 40) else { continue }
            let en = DefinitionText.field(m["exampleEn"], limit: 120)
            meanings.append(WordMeaning(meaning: mm, exampleEn: en, exampleJa: en == nil ? nil : DefinitionText.field(m["exampleJa"], limit: 120)))
            if meanings.count >= 5 { break }
        }
        if !meanings.contains(where: { $0.meaning == meaning }) { meanings.insert(WordMeaning(meaning: meaning, exampleEn: nil, exampleJa: nil), at: 0); meanings = Array(meanings.prefix(5)) }
        let index = (d["contextIndex"] as? Int).flatMap { meanings.indices.contains($0) && meanings[$0].meaning == meaning ? $0 : nil }
            ?? meanings.firstIndex(where: { $0.meaning == meaning }) ?? 0
        return .word(WordCard(lemma: lemma, pos: DefinitionText.field(d["pos"], limit: 12) ?? "", contextMeaning: meaning, contextIndex: index,
                              meanings: meanings, matchInSource: DefinitionText.field(d["matchInSource"], limit: 20),
                              phrases: DefinitionText.fields(d["phrases"], limit: 40, count: 4), note: DefinitionText.field(d["note"], limit: 80)))
    }

    private static func phrase(_ d: [String: Any]) -> DefinitionCard? {
        guard let meaning = DefinitionText.field(d["meaning"], limit: 100) else { return nil }
        return .phrase(PhraseCard(meaning: meaning, nuance: DefinitionText.field(d["nuance"], limit: 100), points: [], synonyms: [], examples: []))
    }

    private static func isLemma(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return s.unicodeScalars.allSatisfy { ($0.isASCII && $0.properties.isAlphabetic) || $0 == "'" || $0 == "’" || $0 == "-" }
    }
}

extension DefinitionCard: Codable {
    private enum Key: String, CodingKey { case kind, word, phrase }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "word": self = .word(try c.decode(WordCard.self, forKey: .word))
        case "phrase": self = .phrase(try c.decode(PhraseCard.self, forKey: .phrase))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown card kind")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .word(let w): try c.encode("word", forKey: .kind); try c.encode(w, forKey: .word)
        case .phrase(let p): try c.encode("phrase", forKey: .kind); try c.encode(p, forKey: .phrase)
        }
    }
}

enum DefinitionText {
    /// Control characters and invisible direction/format characters out, white space folded to one space.
    static func line(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for sc in s.unicodeScalars {
            if sc.properties.generalCategory == .control || sc == "\u{2028}" || sc == "\u{2029}" || sc.properties.isWhitespace {
                if !lastSpace { out.unicodeScalars.append(" ") }; lastSpace = true; continue
            }
            if sc.properties.generalCategory == .format && sc != "\u{200D}" { continue }
            out.unicodeScalars.append(sc); lastSpace = false
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Characters that make a string untrustworthy: control characters (other than white space) and invisible
    /// direction / zero-width characters (except the joiner that emoji need).
    static func isHidden(_ sc: Unicode.Scalar) -> Bool {
        (sc.properties.generalCategory == .control && !sc.properties.isWhitespace) || (sc.properties.generalCategory == .format && sc != "\u{200D}")
    }

    /// A field of the server's answer: a clean one-line string within the limit, or nil (refused, never repaired).
    static func field(_ value: Any?, limit: Int) -> String? {
        guard let s = value as? String, !s.unicodeScalars.contains(where: isHidden) else { return nil }
        let t = line(s)
        guard !t.isEmpty, t.unicodeScalars.count <= limit else { return nil }
        return t
    }

    static func fields(_ value: Any?, limit: Int, count: Int) -> [String] {
        var out: [String] = []
        for item in (value as? [Any] ?? []) {
            if let t = field(item, limit: limit), !out.contains(t) { out.append(t) }
            if out.count >= count { break }
        }
        return out
    }
}
