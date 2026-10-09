import Foundation

public enum TranslationUnit: String, Equatable, Sendable { case phrase, sentence }

public enum BridgeRequest: Equatable {
    case ready
    case translate(gen: Int, text: String)   // ratio / unit come from Swift settings, never from the page
    case save(english: String, japanese: String)   // "辞書に保存": the person tapped the button in the popover
    case lookup(LookupRequest)                      // "意味を調べる": open the lookup sheet (the page never sees the card)
}

public enum BridgeError: Error, Equatable { case malformed(String) }

/// Strict validation of the message a page-side script posts. Anything unexpected is refused, so
/// even if a page managed to post here it could only ask for what the script may ask for.
public enum BridgeMessage {
    public static let maxScalars = 1000   // the server counts Python code points, not Characters

    public static func parse(_ body: Any) -> Result<BridgeRequest, BridgeError> {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return .failure(.malformed("type")) }
        switch type {
        case "ready":
            return Set(dict.keys) == ["type"] ? .success(.ready) : .failure(.malformed("keys"))
        case "translate":
            guard Set(dict.keys) == ["type", "gen", "text"] else { return .failure(.malformed("keys")) }
            guard let gen = integer(dict["gen"]), gen >= 0 else { return .failure(.malformed("gen")) }
            guard let text = dict["text"] as? String, validText(text) else { return .failure(.malformed("text")) }
            return .success(.translate(gen: gen, text: text))
        case "save":
            guard Set(dict.keys) == ["type", "en", "ja"] else { return .failure(.malformed("keys")) }
            guard let en = dict["en"] as? String, validTerm(en), let ja = dict["ja"] as? String, validTerm(ja) else { return .failure(.malformed("term")) }
            return .success(.save(english: en, japanese: ja))
        case "lookup":
            guard Set(dict.keys) == ["type", "kind", "term", "en", "ja"] else { return .failure(.malformed("keys")) }
            guard let kindRaw = dict["kind"] as? String, let kind = LookupKind(rawValue: kindRaw),
                  let term = dict["term"] as? String, let en = dict["en"] as? String, let ja = dict["ja"] as? String,
                  term.unicodeScalars.count <= LookupRequest.maxPhraseScalars, en.unicodeScalars.count <= 4 * LookupRequest.maxContextScalars,
                  ja.unicodeScalars.count <= 4 * LookupRequest.maxContextScalars,
                  let request = LookupRequest.make(kind: kind, term: term, contextEnglish: en, contextJapanese: ja) else { return .failure(.malformed("lookup")) }
            return .success(.lookup(request))
        default:
            return .failure(.malformed("type"))
        }
    }

    /// A saved expression: short, non-empty, no NUL. (DictionaryData cleans it further.)
    public static func validTerm(_ text: String) -> Bool {
        let count = text.unicodeScalars.count
        guard count >= 1, count <= DictionaryData.maxTermScalars * 2 else { return false }
        if text.unicodeScalars.contains(where: { $0.value == 0 }) { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func validText(_ text: String) -> Bool {
        let count = text.unicodeScalars.count
        guard count >= 1, count <= maxScalars else { return false }
        if text.unicodeScalars.contains(where: { $0.value == 0 }) { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func integer(_ v: Any?) -> Int? {
        guard let v, !isBool(v), let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 9_007_199_254_740_992 else { return nil }
        return Int(d)
    }
}
