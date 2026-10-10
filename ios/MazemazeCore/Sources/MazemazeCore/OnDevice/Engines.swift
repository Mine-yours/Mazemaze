import Foundation

/// Where a translation / a word meaning is made. The Mac (the local Ollama model, reached over the LAN or
/// Tailscale) is the original; the other engines run entirely inside the iPhone (no network, no server).
public enum TranslationEngineKind: String, CaseIterable, Equatable, Sendable {
    case mac, appleTranslation, foundationModels

    public var title: String {
        switch self {
        case .mac: return "Mac（ローカルモデル）"
        case .appleTranslation: return "iPhone: Apple 翻訳"
        case .foundationModels: return "iPhone: Apple Intelligence"
        }
    }
    public var runsOnDevice: Bool { self != .mac }
    /// One line for the settings: what it needs and what to expect.
    public var hint: String {
        switch self {
        case .mac: return "いちばん自然に訳せます。Mac が必要です（同じ Wi-Fi か Tailscale）。"
        case .appleTranslation: return "Mac 不要で速い。訳は直訳寄りです。日本語→英語のデータを、最初に一度ダウンロードします。"
        case .foundationModels: return "Mac 不要。iPhone 15 Pro 以降・iOS 26 以降で、Apple Intelligence をオンにしている必要があります。訳の質は Mac より落ちます。"
        }
    }
}

public enum MeaningEngineKind: String, CaseIterable, Equatable, Sendable {
    case mac, foundationModels
    public var title: String { self == .mac ? "Mac（ローカルモデル）" : "iPhone: Apple Intelligence" }
    public var runsOnDevice: Bool { self != .mac }
    public var hint: String {
        self == .mac ? "「この文での意味（AI）」を、Mac のモデルが作ります。"
                     : "Mac 不要。「この文での意味（AI）」を、iPhone の Apple Intelligence が作ります（標準辞書とは別です）。"
    }
}

public struct EnginePrefs: Equatable, Sendable {
    public var translation: TranslationEngineKind = .mac
    public var meaning: MeaningEngineKind = .mac
    /// When the Mac cannot be reached, use `deviceTranslation` / the on-device meaning engine instead of failing.
    public var fallbackToDevice = false
    public var deviceTranslation: TranslationEngineKind = .appleTranslation
    public init() {}
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

/// Makes the model's JSON answer for a word / phrase card. The JSON has the shape the Mac server asks Ollama for
/// (backend/define.py); `OnDeviceDefinition.card` validates it exactly like the server does.
public protocol DefinitionEngine: Sendable {
    var identifier: String { get }
    func answer(kind: LookupKind, detail: DefinitionDetail, term: String, contextEnglish: String, contextJapanese: String, sense: String) async throws -> String
}

/// Gives the service the engines that live in the app (they use iOS frameworks the package does not link).
public protocol DeviceEngineProvider: Sendable {
    func translationEngine(_ kind: TranslationEngineKind) -> SpanTranslationEngine?
    func definitionEngine() -> DefinitionEngine?
}

/// What the settings imply (pure, so it can be tested): when the Mac is needed, and when something can translate at all.
public enum EngineRules {
    /// The first-run "set up the Mac" prompt. Only when the Mac is what translates pages and nothing else (the iPhone) could.
    public static func needsMacSetup(_ p: EnginePrefs, hasServerConfig: Bool) -> Bool {
        p.translation == .mac && !hasServerConfig && !p.fallbackToDevice
    }
    /// Something can translate pages right now: an engine on the iPhone, a fallback to it, or a configured Mac.
    public static func translationAvailable(_ p: EnginePrefs, hasServerConfig: Bool) -> Bool {
        p.translation.runsOnDevice || p.fallbackToDevice || hasServerConfig
    }
    public static func meaningAvailable(_ p: EnginePrefs, hasServerConfig: Bool) -> Bool {
        p.meaning.runsOnDevice || p.fallbackToDevice || hasServerConfig
    }
}
