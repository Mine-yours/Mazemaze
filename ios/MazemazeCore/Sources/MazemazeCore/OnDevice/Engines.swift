import Foundation

/// Which engine translates pages. Both run entirely inside the iPhone (no network, no server).
public enum TranslationEngineKind: String, CaseIterable, Equatable, Sendable {
    case appleTranslation, foundationModels

    public var title: String {
        switch self {
        case .appleTranslation: return "Apple 翻訳"
        case .foundationModels: return "Apple Intelligence"
        }
    }
    /// One line for the settings: what it needs and what to expect.
    public var hint: String {
        switch self {
        case .appleTranslation: return "速くて軽い。訳は直訳寄りです。日本語→英語のデータを、最初に一度ダウンロードします。"
        case .foundationModels: return "iPhone 15 Pro 以降・iOS 26 以降で、Apple Intelligence をオンにしている必要があります。文脈を見ますが、訳の質は Apple 翻訳と違う癖があります。"
        }
    }
}

public enum EngineError: Error, Equatable, Sendable {
    /// The engine cannot run at all right now (not supported, not enabled, language pack missing). The text is Japanese
    /// and safe to show (never contains page text).
    case unavailable(String)
    /// This call failed (the model refused, produced nothing usable, was interrupted). The spans stay Japanese.
    case failed(String)
}

/// Translates the spans the app chose. The engine never decides what to replace and never sees more than the
/// text it needs: the app validates every answer (SpanRules) and keeps everything else byte-for-byte.
public protocol SpanTranslationEngine: Sendable {
    var identifier: String { get }
    /// English for each span id. Ids that are missing stay Japanese. `text` is the whole page block (context only).
    func translate(text: String, spans: [SelectedSpan]) async throws -> [String: String]
}

public enum DefinitionDetail: String, Sendable { case basic, more }

/// Makes the model's JSON answer for a word / phrase card. The JSON has the shape the Mac version asked Ollama for
/// (backend/define.py on branch mac-local-model); `OnDeviceDefinition.card` validates it like the server did.
public protocol DefinitionEngine: Sendable {
    var identifier: String { get }
    func answer(kind: LookupKind, detail: DefinitionDetail, term: String, contextEnglish: String, contextJapanese: String, sense: String) async throws -> String
}

/// Gives the service the engines that live in the app (they use iOS frameworks the package does not link).
public protocol DeviceEngineProvider: Sendable {
    func translationEngine(_ kind: TranslationEngineKind) -> SpanTranslationEngine?
    func definitionEngine() -> DefinitionEngine?
}
