import Foundation

/// Runs the whole translation on the iPhone: choose spans (SpanSelector), ask the engine in small batches, validate
/// every answer (SpanRules) and rebuild the text from slices of itself. Anything that fails stays Japanese, so the
/// original text can always be reproduced exactly (CLAUDE.md §5).
public enum OnDeviceTranslator {
    public static let maxSpans = 24
    public static let batchMaxSpans = 6
    public static let batchMaxChars = 150

    /// Same grouping as the server (backend/service.py `batch_spans`).
    public static func batches(_ spans: [SelectedSpan]) -> [[SelectedSpan]] {
        var out: [[SelectedSpan]] = [], current: [SelectedSpan] = [], chars = 0
        for s in spans {
            let n = s.source.unicodeScalars.count
            if !current.isEmpty, current.count >= batchMaxSpans || chars + n > batchMaxChars { out.append(current); current = []; chars = 0 }
            current.append(s); chars += n
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// CJK punctuation / full-width forms are not English (the server rejects them the same way).
    static func hasFullWidth(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    public struct Result: Equatable, Sendable {
        public var segments: [TranslatedSegment]
        public var requestedSpans: Int
        public var failedBatches: Int
    }

    /// Throws `EngineError.unavailable` when the engine cannot run, `.failed` when every batch failed, and
    /// `CancellationError` when the task is cancelled. Otherwise returns the (possibly partly Japanese) text.
    public static func translate(text: String, ratio: Double, unit: TranslationUnit, engine: SpanTranslationEngine) async throws -> Result {
        let t = Array(text.unicodeScalars)
        let selection = try SpanSelector.select(text: text, ratio: ratio, unit: unit, maxSpans: maxSpans)
        var translations: [String: String] = [:]
        var failed = 0
        var lastFailure = ""
        let groups = batches(selection.spans)
        for group in groups {
            try Task.checkCancellation()
            do {
                let answer = try await engine.translate(text: text, spans: group)
                let ids = Set(group.map(\.id))
                for (id, en) in answer where ids.contains(id) && !hasFullWidth(en) { translations[id] = en }
            } catch let e as EngineError {
                if case .unavailable = e { throw e }
                if case .failed(let why) = e { lastFailure = why }
                failed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
            }
        }
        if !groups.isEmpty, failed == groups.count { throw EngineError.failed(lastFailure.isEmpty ? "翻訳できませんでした" : lastFailure) }

        var segments = try SpanRules.assemble(t, selection.spans, translations)
        var display = DisplayFormat.segments(t, segments)
        if !DisplayFormat.outsidePreserved(t, display) {
            segments = try SpanRules.assemble(t, [], [:])
            display = DisplayFormat.segments(t, segments)
        }
        let out = display.map { TranslatedSegment(kind: $0.kind == .en ? .en : .ja, source: $0.source, display: $0.display) }
        // The same check the app applies to the Mac's answer: the pieces rebuild exactly the text that was asked about.
        guard Array(out.map(\.source).joined().unicodeScalars) == t else { throw EngineError.failed("原文を保持できなかったため、変換しませんでした") }
        return Result(segments: out, requestedSpans: selection.spans.count, failedBatches: failed)
    }
}
