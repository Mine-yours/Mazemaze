import XCTest
@testable import MazemazeCore

actor AsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; let w = waiters; waiters = []; w.forEach { $0.resume() } }
}

final class ManualClock: ServiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    private(set) var sleeps: [Double] = []
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
    func sleep(seconds: Double) async throws { lock.lock(); sleeps.append(seconds); t += seconds; lock.unlock(); await Task.yield() }
}

final class LockedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}

final class FirstCall: @unchecked Sendable {
    private let l = NSLock(); private var seen = false
    func isFirst() -> Bool { l.lock(); defer { l.unlock() }; defer { seen = true }; return !seen }
}

final class PrefsBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: (ratio: Double, unit: TranslationUnit) = (0.3, .phrase)
    var value: (ratio: Double, unit: TranslationUnit) { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

final class EngineKindBox: @unchecked Sendable {
    private let lock = NSLock(); private var k: TranslationEngineKind = .appleTranslation
    var value: TranslationEngineKind { get { lock.lock(); defer { lock.unlock() }; return k } set { lock.lock(); k = newValue; lock.unlock() } }
}

final class OrderBox: @unchecked Sendable {
    private let l = NSLock(); private var items: [String] = []
    func add(_ s: String) { l.lock(); items.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return items }
}

/// A translation engine for tests: records what it was asked (page text and spans), can hold a request open per page text, and
/// answers with `handler` ("Phrase number N" for every span by default).
final class FakeSpanEngine: SpanTranslationEngine, @unchecked Sendable {
    let identifier: String
    private let lock = NSLock()
    private var _calls: [(text: String, spans: [SelectedSpan])] = []
    private var active = 0
    private(set) var maxActive = 0
    var gates: [String: AsyncGate] = [:]          // page text -> gate
    var handler: @Sendable (String, [SelectedSpan]) async throws -> [String: String]
    init(_ id: String = "fake", handler: @escaping @Sendable (String, [SelectedSpan]) async throws -> [String: String] = numberedEnglish) { identifier = id; self.handler = handler }
    var calls: [(text: String, spans: [SelectedSpan])] { lock.lock(); defer { lock.unlock() }; return _calls }
    var count: Int { calls.count }
    var texts: [String] { calls.map(\.text) }
    func translate(text: String, spans: [SelectedSpan]) async throws -> [String: String] {
        lock.lock(); _calls.append((text, spans)); active += 1; maxActive = max(maxActive, active); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if let gate = gates[text] { await gate.wait() }
        return try await handler(text, spans)
    }
}

final class FakeDefinitionEngine: DefinitionEngine, @unchecked Sendable {
    let identifier = "fake-def"
    private let lock = NSLock()
    private var _count = 0
    var handler: @Sendable (LookupKind, DefinitionDetail, String) async throws -> String
    init(handler: @escaping @Sendable (LookupKind, DefinitionDetail, String) async throws -> String) { self.handler = handler }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func answer(kind: LookupKind, detail: DefinitionDetail, term: String, contextEnglish: String, contextJapanese: String, sense: String) async throws -> String {
        lock.lock(); _count += 1; lock.unlock()
        return try await handler(kind, detail, term)
    }
}

final class FakeProvider: DeviceEngineProvider, @unchecked Sendable {
    var translators: [TranslationEngineKind: SpanTranslationEngine] = [:]
    var definer: DefinitionEngine?
    init(_ kind: TranslationEngineKind = .appleTranslation, engine: SpanTranslationEngine? = nil, definer: DefinitionEngine? = nil) {
        if let engine { translators[kind] = engine }
        self.definer = definer
    }
    func translationEngine(_ kind: TranslationEngineKind) -> SpanTranslationEngine? { translators[kind] }
    func definitionEngine() -> DefinitionEngine? { definer }
}

/// An English phrase for every span ("Phrase number N": letters only, always valid).
let numberedEnglish: @Sendable (String, [SelectedSpan]) async throws -> [String: String] = { _, spans in
    Dictionary(uniqueKeysWithValues: spans.map { ($0.id, "Phrase number \(String($0.id.dropFirst()))") })
}

func makeService(_ engine: FakeSpanEngine = FakeSpanEngine(), clock: ManualClock = ManualClock(), prefs: PrefsBox = PrefsBox(),
                 kind: EngineKindBox = EngineKindBox(), definer: DefinitionEngine? = nil,
                 options: TranslationService.Options = .init()) -> TranslationService {
    let provider = FakeProvider(engine: engine, definer: definer)
    provider.translators[.foundationModels] = engine
    return TranslationService(engines: provider, engine: { kind.value }, prefs: { prefs.value }, clock: clock, options: options)
}

/// `XCTAssertEqual` whose first value is computed asynchronously (XCTest autoclosures cannot `await`).
func assertEq<T: Equatable>(_ a: @autoclosure () async -> T, _ b: @autoclosure () -> T, file: StaticString = #filePath, line: UInt = #line) async {
    let x = await a(); XCTAssertEqual(x, b(), file: file, line: line)
}
func assertGreater<T: Comparable>(_ a: @autoclosure () async -> T, _ b: @autoclosure () -> T, file: StaticString = #filePath, line: UInt = #line) async {
    let x = await a(); XCTAssertGreaterThan(x, b(), file: file, line: line)
}
