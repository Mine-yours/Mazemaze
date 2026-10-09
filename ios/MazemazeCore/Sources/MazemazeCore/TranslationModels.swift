import Foundation

public struct TranslatedSegment: Equatable, Sendable {
    public enum Kind: String, Sendable { case ja, en }
    public var kind: Kind
    public var source: String    // original Japanese
    public var display: String   // what the page shows (== source for ja)
    public init(kind: Kind, source: String, display: String) { self.kind = kind; self.source = source; self.display = display }
}

public enum ResponseError: Error, Equatable { case invalid(String) }

enum APIDecoding {
    struct Segment: Decodable { let kind: String; let source: String; let display: String }
    struct Body: Decodable { let segments: [Segment] }
    struct ErrorBody: Decodable { struct E: Decodable { let code: String?; let message: String? }; let error: E? }
    struct Status: Decodable {
        let model: String?
        let ollama_reachable: Bool?
        let model_installed: Bool?
        let model_metadata_ok: Bool?
        let busy: Bool?
        let deadline_seconds: Double?
    }

    /// Decodes and re-verifies the server response on the app side too: the pieces must rebuild
    /// exactly the text that was sent, Japanese pieces must be untouched, English pieces non-empty
    /// single-line text. Anything else is discarded (the page keeps its original text).
    static func segments(from data: Data, requestText: String) -> Result<[TranslatedSegment], ResponseError> {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return .failure(.invalid("json")) }
        var out: [TranslatedSegment] = []
        var rebuilt = ""
        for s in body.segments {
            guard let kind = TranslatedSegment.Kind(rawValue: s.kind) else { return .failure(.invalid("kind")) }
            if s.source.isEmpty { return .failure(.invalid("empty source")) }
            switch kind {
            case .ja:
                if s.display != s.source { return .failure(.invalid("ja changed")) }
            case .en:
                let d = s.display
                if d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || d.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0.value == 0 }) {
                    return .failure(.invalid("en display"))
                }
                if s.source.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return .failure(.invalid("en source")) }
            }
            rebuilt += s.source
            out.append(TranslatedSegment(kind: kind, source: s.source, display: s.display))
        }
        // Compare scalars, not Characters or normalized strings.
        guard Array(rebuilt.unicodeScalars) == Array(requestText.unicodeScalars) else { return .failure(.invalid("source mismatch")) }
        return .success(out)
    }
}
