import XCTest
@testable import MazemazeCore

/// The Swift port must give exactly what the Python reference (backend/) gives, for thousands of inputs
/// (scripts/gen_ondevice_golden.py writes them). A single difference means the on-device path could keep
/// different text than the Mac path, so every case is checked and the first few failures are printed.
final class OnDeviceGoldenTests: XCTestCase {
    struct Golden {
        let texts: [String]
        let selection: [[String: Any]]
        let counted: [Int]
        let validation: [[String: Any]]
        let assembly: [[String: Any]]
        let cards: [[String: Any]]
    }
    static let golden: Golden = {
        let url = Bundle.module.url(forResource: "ondevice_golden", withExtension: "json")!
        let o = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return Golden(texts: o["texts"] as! [String], selection: o["selection"] as! [[String: Any]], counted: o["counted"] as! [Int],
                      validation: o["validation"] as! [[String: Any]], assembly: o["assembly"] as! [[String: Any]], cards: o["cards"] as! [[String: Any]])
    }()

    func describe(_ s: String) -> String { String(s.debugDescription.prefix(120)) }

    func testCountedLengthMatchesPython() {
        var bad = 0
        for (i, t) in Self.golden.texts.enumerated() where SpanSelector.countedLength(t) != Self.golden.counted[i] {
            bad += 1; if bad <= 5 { XCTFail("counted \(describe(t)): \(SpanSelector.countedLength(t)) != \(Self.golden.counted[i])") }
        }
        XCTAssertEqual(bad, 0)
    }

    func testSelectionMatchesPython() {
        var bad = 0, withSpans = 0
        for c in Self.golden.selection {
            let text = Self.golden.texts[c["t"] as! Int]
            let unit: TranslationUnit = (c["unit"] as! String) == "phrase" ? .phrase : .sentence
            let ratio = c["ratio"] as! Double, seed = c["seed"] as! Int
            let mx = c["max"] as? Int
            let got = try? SpanSelector.select(text: text, ratio: ratio, unit: unit, seed: seed, maxSpans: mx)
            if c["error"] != nil { XCTAssertNil(got, "expected an error for \(describe(text))"); continue }
            let want = (c["spans"] as! [[Any]]).map { SelectedSpan(id: $0[0] as! String, start: $0[1] as! Int, end: $0[2] as! Int, source: $0[3] as! String) }
            if !want.isEmpty { withSpans += 1 }
            if got?.spans != want || got?.candidates != (c["candidates"] as! Int) || abs((got?.actualRatio ?? -1) - (c["actual"] as! Double)) > 1e-12 {
                bad += 1
                if bad <= 5 { XCTFail("selection \(describe(text)) \(unit) \(ratio) seed \(seed): \(String(describing: got?.spans.map { $0.source })) != \(want.map { $0.source })") }
            }
        }
        XCTAssertEqual(bad, 0)
        XCTAssertGreaterThan(withSpans, 500, "the vectors must actually exercise span selection")
    }

    func testValidationMatchesPython() {
        var bad = 0, accepted = 0, rejected = 0
        for c in Self.golden.validation {
            let want = c["verdict"] as? String
            let got = SpanRules.validate(source: c["source"] as! String, en: c["en"] as! String, outside: c["outside"] as! String)
            if want == nil { accepted += 1 } else { rejected += 1 }
            if got != want {
                bad += 1
                if bad <= 8 { XCTFail("validate source=\(describe(c["source"] as! String)) en=\(describe(c["en"] as! String)) outside=\(describe(c["outside"] as! String)): \(got ?? "ok") != \(want ?? "ok")") }
            }
        }
        XCTAssertEqual(bad, 0)
        XCTAssertGreaterThan(accepted, 100); XCTAssertGreaterThan(rejected, 100)
    }

    func testAssemblyAndDisplayMatchPython() throws {
        var bad = 0, ok = 0
        for c in Self.golden.assembly {
            let text = Self.golden.texts[c["t"] as! Int]
            let t = Array(text.unicodeScalars)
            let spans = (c["spans"] as! [[Any]]).map { SelectedSpan(id: $0[0] as! String, start: $0[1] as! Int, end: $0[2] as! Int, source: $0[3] as! String) }
            let tr = c["translations"] as! [String: String]
            guard let want = c["segments"] as? [[Any]] else { XCTAssertNotNil(c["error"]); continue }
            do {
                let segs = DisplayFormat.segments(t, try SpanRules.assemble(t, spans, tr))
                let got = segs.map { [$0.kind.rawValue, $0.text, $0.display, $0.source, $0.start, $0.end] as [Any] }
                let same = got.count == want.count && zip(got, want).allSatisfy { a, b in
                    (a[0] as! String) == (b[0] as! String) && (a[1] as! String) == (b[1] as! String) && (a[2] as! String) == (b[2] as! String)
                        && (a[3] as! String) == (b[3] as! String) && (a[4] as! Int) == (b[4] as! Int) && (a[5] as! Int) == (b[5] as! Int)
                }
                let joined = segs.map { $0.display }.joined()
                if same && joined == (c["joined"] as! String) && DisplayFormat.outsidePreserved(t, segs) == (c["preserved"] as! Bool) { ok += 1 }
                else { bad += 1; if bad <= 5 { XCTFail("assembly \(describe(text)): \(joined.debugDescription) != \((c["joined"] as! String).debugDescription)") } }
            } catch { bad += 1; if bad <= 5 { XCTFail("assembly threw for \(describe(text)): \(error)") } }
        }
        XCTAssertEqual(bad, 0)
        XCTAssertGreaterThan(ok, 300)
    }

    func testCardValidationMatchesPython() {
        var bad = 0, valid = 0
        for c in Self.golden.cards {
            let kind: LookupKind = (c["kind"] as! String) == "word" ? .word : .phrase
            let detail: DefinitionDetail = (c["detail"] as! String) == "basic" ? .basic : .more
            let got = OnDeviceDefinition.card(kind: kind, detail: detail, content: c["content"] as! String, contextJapanese: c["ctx"] as! String)
            let want = c["card"] as? [String: Any]
            if want != nil { valid += 1 }
            let same = (got == nil && want == nil) || (got != nil && want != nil && (got! as NSDictionary).isEqual(to: want!))
            if !same {
                bad += 1
                if bad <= 6 { XCTFail("card \(kind) \(detail) \(describe(c["content"] as! String)): \(String(describing: got)) != \(String(describing: want))") }
            }
        }
        XCTAssertEqual(bad, 0)
        XCTAssertGreaterThan(valid, 500)
    }
}
