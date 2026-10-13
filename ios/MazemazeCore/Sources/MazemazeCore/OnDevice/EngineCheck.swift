import Foundation

/// A fixed set of Japanese sentences run through an engine by hand (Settings > エンジンの確認), to see how a new iOS version or a
/// changed model behaves: does the original stay intact, how many phrases are accepted, how long it takes, what the English looks
/// like. A maintenance tool, not part of reading; nothing is stored or sent.
public struct EngineCheckItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: String
    public let text: String
}

public struct EngineCheckResult: Equatable, Sendable, Identifiable {
    public var id: String
    public var category: String
    public var mixed: String
    public var requestedSpans: Int
    public var acceptedSpans: Int
    public var failedBatches: Int
    public var seconds: Double
    public var error: String?
    /// The pieces rebuild exactly the sentence that went in.
    public var preserved: Bool
}

public struct EngineCheckSummary: Equatable, Sendable {
    public var texts: Int
    public var preservedAll: Bool
    public var requestedSpans: Int
    public var acceptedSpans: Int
    public var errors: Int
    public var averageSeconds: Double

    public var text: String {
        "\(texts) 文 / 原文の保持: \(preservedAll ? "すべて一致" : "不一致あり") / 英語にできた句: \(acceptedSpans)/\(requestedSpans) / エラー: \(errors) 件 / 平均 \(String(format: "%.1f", averageSeconds)) 秒"
    }
}

public enum EngineCheck {
    public static func items(from data: Data) -> [EngineCheckItem] {
        (try? JSONDecoder().decode([EngineCheckItem].self, from: data)) ?? []
    }

    public static func run(items: [EngineCheckItem], engine: SpanTranslationEngine, ratio: Double, unit: TranslationUnit,
                           progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [EngineCheckResult] {
        var out: [EngineCheckResult] = []
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            progress(i, items.count)
            let started = Date()
            do {
                let r = try await OnDeviceTranslator.translate(text: item.text, ratio: ratio, unit: unit, engine: engine)
                let preserved = Array(r.segments.map(\.source).joined().unicodeScalars) == Array(item.text.unicodeScalars)
                out.append(EngineCheckResult(id: item.id, category: item.category, mixed: r.segments.map(\.display).joined(), requestedSpans: r.requestedSpans,
                                             acceptedSpans: r.segments.filter { $0.kind == .en }.count, failedBatches: r.failedBatches,
                                             seconds: Date().timeIntervalSince(started), error: nil, preserved: preserved))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let why: String
                if let e = error as? EngineError { switch e { case .unavailable(let m), .failed(let m): why = m } } else { why = "失敗" }
                out.append(EngineCheckResult(id: item.id, category: item.category, mixed: item.text, requestedSpans: 0, acceptedSpans: 0, failedBatches: 0,
                                             seconds: Date().timeIntervalSince(started), error: why, preserved: true))
            }
        }
        progress(items.count, items.count)
        return out
    }

    public static func summarize(_ results: [EngineCheckResult]) -> EngineCheckSummary {
        EngineCheckSummary(texts: results.count, preservedAll: results.allSatisfy(\.preserved), requestedSpans: results.map(\.requestedSpans).reduce(0, +),
                           acceptedSpans: results.map(\.acceptedSpans).reduce(0, +), errors: results.filter { $0.error != nil }.count,
                           averageSeconds: results.isEmpty ? 0 : results.map(\.seconds).reduce(0, +) / Double(results.count))
    }
}
