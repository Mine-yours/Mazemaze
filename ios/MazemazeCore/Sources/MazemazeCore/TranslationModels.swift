import Foundation

public struct TranslatedSegment: Equatable, Sendable {
    public enum Kind: String, Sendable { case ja, en }
    public var kind: Kind
    public var source: String    // original Japanese
    public var display: String   // what the page shows (== source for ja)
    public init(kind: Kind, source: String, display: String) { self.kind = kind; self.source = source; self.display = display }
}
