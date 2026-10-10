import Foundation

/// Validation of a word / phrase card made by an on-device model (port of `parse_card` in backend/define.py).
/// The model's output is never trusted: every field is checked for type and length, control characters are
/// refused, and anything unusable is dropped. The result has the shape of the answer the Mac version's server gave (branch mac-local-model), so the app
/// decodes it with `DefinitionCard.decode` — the same second check the original path had.
public enum OnDeviceDefinition {
    static let lemmaPattern = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z'’-]{0,39}$")

    /// Control characters (other than white space) and invisible format characters (direction overrides, zero-width
    /// characters, soft hyphen, ...) except the joiner emoji need.
    static func hidden(_ s: String) -> Bool {
        s.unicodeScalars.contains { c in
            let cat = PyText.category(c)
            return (cat == .control && !PyText.isSpace(c)) || (cat == .format && c.value != 0x200D)
        }
    }

    /// A clean one-line string within `limit` characters, or nil.
    static func text(_ value: Any?, _ limit: Int) -> String? {
        guard let s = value as? String, !(value is NSNull) else { return nil }
        let folded = foldSpaces(s)
        guard !folded.isEmpty, folded.unicodeScalars.count <= limit, !hidden(s) else { return nil }
        return folded
    }

    /// `" ".join(value.split())`
    static func foldSpaces(_ s: String) -> String {
        var words: [String] = [], cur = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if PyText.isSpace(c) { if !cur.isEmpty { words.append(String(cur)); cur = String.UnicodeScalarView() } } else { cur.append(c) }
        }
        if !cur.isEmpty { words.append(String(cur)) }
        return words.joined(separator: " ")
    }

    static func texts(_ value: Any?, _ limit: Int, _ count: Int) -> [String] {
        guard let list = value as? [Any] else { return [] }
        var out: [String] = []
        for item in list {
            if let t = text(item, limit), !out.contains(t) { out.append(t) }
            if out.count >= count { break }
        }
        return out
    }

    static func example(_ value: Any?) -> [String: Any]? {
        guard let d = value as? [String: Any], let en = text(d["en"], 120) else { return nil }
        return ["en": en, "ja": text(d["ja"], 120) ?? ""]
    }

    /// A JSON integer (not a boolean, not a float), like Python's `isinstance(x, int) and not isinstance(x, bool)`.
    static func integer(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.intValue
    }

    /// Fixes what a small model is bad at, before the usual validation: the base form and part of speech come from the system's
    /// language analysis (not from the model), and "more" lists lose the entries that only repeat the sentence or the word.
    public static func refine(kind: LookupKind, detail: DefinitionDetail, term: String, contextEnglish: String, content: String) -> String {
        guard let data = content.data(using: .utf8), var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return content }
        switch (kind, detail) {
        case (.word, .basic):
            // The glosses are Japanese: an entry without any Japanese character (the model answered in English) is dropped, and the
            // index of the sense in context follows. If that sense itself was dropped, the answer is unusable (index -1 → refused).
            if let senses = d["senses"] as? [Any], let index = integer(d["contextIndex"]), senses.indices.contains(index) {
                func gloss(_ v: Any) -> String { ((v as? [String: Any])?["gloss"] as? String) ?? (v as? String) ?? "" }
                let kept = senses.enumerated().filter { hasJapanese(gloss($0.element)) }
                d["senses"] = kept.map { $0.element }
                d["contextIndex"] = kept.firstIndex(where: { $0.offset == index }) ?? -1
            }
            if let a = EnglishAnalyzer.analyze(term: term, context: contextEnglish) {
                d["lemma"] = a.lemma
                if let pos = a.pos { d["pos"] = pos }
            } else if d["lemma"] == nil { d["lemma"] = term.lowercased() }
        case (.word, .more):
            let example = ((d["example"] as? [String: Any])?["en"] as? String)?.lowercased()
            d["phrases"] = (d["phrases"] as? [Any] ?? []).filter { item in
                guard let s = item as? String else { return false }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return !t.hasSuffix(".") && !t.hasSuffix("?") && !t.hasSuffix("!") && t.lowercased() != example && t.lowercased() != term.lowercased()
            }
        case (.phrase, .more):
            d["synonyms"] = (d["synonyms"] as? [Any] ?? []).filter { ($0 as? String)?.lowercased() != term.lowercased() }
        case (.phrase, .basic): break
        }
        return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? content
    }

    static func hasJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    /// The validated card (or "more" part), or nil when the answer cannot be used. Never throws.
    public static func card(kind: LookupKind, detail: DefinitionDetail, content: String, contextJapanese: String) -> [String: Any]? {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let d = obj as? [String: Any] else { return nil }
        switch (kind, detail) {
        case (.word, .basic): return wordBasic(d, contextJapanese)
        case (.word, .more): return wordMore(d)
        case (.phrase, .basic): return phraseBasic(d)
        case (.phrase, .more): return phraseMore(d)
        }
    }

    /// `{"card": ...}`: the original server answer's shape, ready for `DefinitionCard.decode` / `DefinitionMore.decode`.
    public static func serverResponse(kind: LookupKind, detail: DefinitionDetail, content: String, contextJapanese: String) -> Data? {
        guard let c = card(kind: kind, detail: detail, content: content, contextJapanese: contextJapanese) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["card": c, "model": "on-device"])
    }

    static func wordBasic(_ d: [String: Any], _ contextJa: String) -> [String: Any]? {
        guard let lemma = text(d["lemma"], 40),
              lemmaPattern.firstMatch(in: lemma, options: [], range: NSRange(location: 0, length: (lemma as NSString).length)) != nil else { return nil }
        let raw = d["senses"] as? [Any] ?? []
        func gloss(_ s: Any) -> String? { text((s as? [String: Any]).map { $0["gloss"] } ?? s, 40) }
        var senses: [String] = []
        for s in raw {
            if let g = gloss(s), !senses.contains(g) { senses.append(g) }
            if senses.count >= 5 { break }
        }
        guard !senses.isEmpty, let index = integer(d["contextIndex"]), raw.indices.contains(index) else { return nil }
        // `index` counts the model's list; map it onto the cleaned list (an unusable gloss before it shifts the position).
        guard let chosen = gloss(raw[index]), let at = senses.firstIndex(of: chosen) else { return nil }
        var card: [String: Any] = ["kind": "word", "lemma": lemma, "pos": text(d["pos"], 12) ?? "", "contextMeaning": chosen,
                                   "contextIndex": at, "meanings": senses.map { ["meaning": $0] }]
        if let match = text(d["matchInSource"], 20), !contextJa.isEmpty, contextJa.contains(match) { card["matchInSource"] = match }   // only what really is in the Japanese original
        return card
    }

    static func wordMore(_ d: [String: Any]) -> [String: Any]? {
        let ex = example(d["example"]), phrases = texts(d["phrases"], 40, 4), note = text(d["note"], 80)
        guard ex != nil || !phrases.isEmpty || note != nil else { return nil }
        var out: [String: Any] = ["kind": "word_more", "phrases": phrases]
        if let ex { out["example"] = ex }
        if let note { out["note"] = note }
        return out
    }

    static func phraseBasic(_ d: [String: Any]) -> [String: Any]? {
        guard let meaning = text(d["meaning"], 100) else { return nil }
        var card: [String: Any] = ["kind": "phrase", "meaning": meaning]
        if let nuance = text(d["nuance"], 100) { card["nuance"] = nuance }
        return card
    }

    static func phraseMore(_ d: [String: Any]) -> [String: Any]? {
        var points: [[String: Any]] = []
        for p in (d["points"] as? [Any] ?? []) {
            guard let p = p as? [String: Any] else { continue }
            if let expr = text(p["expr"], 80) { points.append(["expr": expr, "note": text(p["note"], 80) ?? ""]) }
            if points.count >= 2 { break }
        }
        let synonyms = texts(d["synonyms"], 60, 3), ex = example(d["example"])
        guard !points.isEmpty || !synonyms.isEmpty || ex != nil else { return nil }
        var out: [String: Any] = ["kind": "phrase_more", "points": points, "synonyms": synonyms]
        if let ex { out["example"] = ex }
        return out
    }
}
