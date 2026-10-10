import Foundation
import NaturalLanguage

/// The base form and the part of speech of an English word, from the system's own language analysis (on the device, no
/// network, no model). A small language model gets these wrong (it returned "e" for "have" and "st" for "stroll"), so
/// the cards never depend on it for them.
public enum EnglishAnalyzer {
    public struct Analysis: Equatable, Sendable {
        public let lemma: String
        public let pos: String?          // in Japanese ("動詞"), or nil when unknown
    }

    static func japanese(_ tag: NLTag) -> String? {
        switch tag {
        case .noun: return "名詞"
        case .verb: return "動詞"
        case .adjective: return "形容詞"
        case .adverb: return "副詞"
        case .preposition: return "前置詞"
        case .pronoun: return "代名詞"
        case .conjunction: return "接続詞"
        case .determiner: return "限定詞"
        case .interjection: return "間投詞"
        default: return nil
        }
    }

    /// `term` as it is used in `context` (the English phrase it was read in); falls back to the word alone.
    public static func analyze(term: String, context: String) -> Analysis? {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }
        let text = context.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil ? context : word
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var found: Analysis?
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard text[range].caseInsensitiveCompare(word) == .orderedSame else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            found = Analysis(lemma: (lemma?.isEmpty == false ? lemma! : String(text[range])).lowercased(), pos: tag.flatMap(japanese))
            return false
        }
        return found
    }
}
