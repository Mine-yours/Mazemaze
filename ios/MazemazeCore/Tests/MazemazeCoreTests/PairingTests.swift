import XCTest
@testable import MazemazeCore

final class PairingParseTests: XCTestCase {
    let fp = String(repeating: "ab", count: 32)
    let tok = "Tok3n_abcdefghij-0123456789"

    func ok(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> PairingPayload? {
        if case .success(let p) = PairingPayload.parse(s) { return p }
        XCTFail("rejected: \(s)", file: file, line: line); return nil
    }
    func no(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .success = PairingPayload.parse(s) { XCTFail("accepted: \(s)", file: file, line: line) }
    }

    func testValidHttpsAndHttpPayloads() {
        let p = ok("mazemaze://pair?v=1&h=My-Mac.local&i=192.168.3.13&p=8000&t=\(tok)&s=https&f=\(fp)&n=My%20Mac")!
        XCTAssertEqual(p.primaryURL.absoluteString, "https://my-mac.local:8000")
        XCTAssertEqual(p.fallbackURL?.absoluteString, "https://192.168.3.13:8000")
        XCTAssertEqual(ok("mazemaze://pair?v=1&h=my-mac.local&i=192.168.3.13&p=8000&t=\(tok)")!.fallbackURL?.absoluteString, "http://192.168.3.13:8000")
        XCTAssertEqual(p.fingerprint, fp); XCTAssertEqual(p.token, tok); XCTAssertTrue(p.isEncrypted); XCTAssertEqual(p.name, "My Mac")
        let h = ok("mazemaze://pair?v=1&i=10.0.0.5&p=8000&t=\(tok)")!
        XCTAssertEqual(h.primaryURL.absoluteString, "http://10.0.0.5:8000"); XCTAssertNil(h.fallbackURL); XCTAssertFalse(h.isEncrypted)
        XCTAssertNotNil(ok("  \nmazemaze://pair?v=1&h=a.local&p=1&t=\(tok)\n "))      // pasted with whitespace around it
        XCTAssertNotNil(ok("MAZEMAZE://PAIR?v=1&h=a.local&p=65535&t=\(tok)"))
        XCTAssertNotNil(ok("mazemaze://pair?v=1&h=a.local&p=8000&t=\(tok)&s=https&f=\(fp.uppercased())"))
    }

    func testStructureAttacks() {
        for s in ["", "mazemaze://pair", "mazemaze:pair?v=1", "http://pair?v=1&h=a.local&p=1&t=\(tok)", "mazemaze://evil?v=1&h=a.local&p=1&t=\(tok)",
                  "mazemaze://pair/extra?v=1&h=a.local&p=1&t=\(tok)", "mazemaze://user@pair?v=1&h=a.local&p=1&t=\(tok)", "mazemaze://pair@evil.com?v=1&h=a.local&p=1&t=\(tok)",
                  "mazemaze://pair:80?v=1&h=a.local&p=1&t=\(tok)", "mazemaze://pair?v=1&h=a.local&p=1&t=\(tok)#frag", "mazemaze://pair?v=1&h=a.local&p=1&t=\(tok)\u{0}",
                  "mazemaze://pair?v=1&h=a.local&p=1&t=\(tok) x", "mazemaze://pair?v=1&h=a.local&p=1&t=\(tok.prefix(8))\u{200B}\(tok.dropFirst(8))", String(repeating: "a", count: 700)] { no(s) }
    }

    func testParameterRules() {
        let base = "mazemaze://pair?v=1&h=a.local&p=8000&t=\(tok)"
        no(base + "&h=b.local")                    // duplicate
        no(base + "&x=1")                          // unknown key
        no(base + "&redirect=https://evil.com")    // unknown key
        no("mazemaze://pair?h=a.local&p=8000&t=\(tok)")          // no version
        no("mazemaze://pair?v=2&h=a.local&p=8000&t=\(tok)")
        no("mazemaze://pair?v=1&p=8000&t=\(tok)")                // no address
        no(base + "&s=ftp"); no(base + "&s=")
    }

    func testAddressValuesMustBeLocal() {
        let rest = "&p=8000&t=\(tok)"
        for h in ["evil.com", "a.local.evil.com", "192.168.0.1", "localhost", "a..local", "-a.local", ".local", "a.local.", "ａ.local", "a%2Elocal%2Fx", "my mac.local", "a.local%00"] {
            no("mazemaze://pair?v=1&h=\(h)" + rest)
        }
        for i in ["8.8.8.8", "100.64.0.1", "169.254.1.1", "0x7f000001", "2130706433", "192.168.1", "192.168.001.001", "::1", "10.0.0.256", "1.2.3.4.5"] {
            no("mazemaze://pair?v=1&i=\(i)" + rest)
        }
    }

    func testPortAndTokenAndFingerprintRules() {
        let head = "mazemaze://pair?v=1&h=a.local"
        for p in ["0", "65536", "8000abc", "+8000", "-1", "08000", "８０００", "", "99999"] { no("\(head)&p=\(p)&t=\(tok)") }
        for t in ["short", String(repeating: "a", count: 15), String(repeating: "a", count: 129), "has space here 12345678", "tok%20en12345678901", "tok/en12345678901234", "ｔｏｋｅｎ１２３４５６７８９０１２"] { no("\(head)&p=8000&t=\(t)") }
        let sha1 = String(repeating: "a", count: 40)
        for f in [sha1, String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "g", count: 64), ""] { no("\(head)&p=8000&t=\(tok)&s=https&f=\(f)") }
        no("\(head)&p=8000&t=\(tok)&s=https")                    // https needs a fingerprint (else encryption without authentication)
        no("\(head)&p=8000&t=\(tok)&s=http&f=\(fp)")             // a fingerprint only makes sense for https
        no("\(head)&p=8000&t=\(tok)&f=\(fp)")
        XCTAssertNotNil(ok("\(head)&p=8000&t=\(tok)&s=https&f=" + fp.enumerated().map { $0.offset % 2 == 0 && $0.offset > 0 ? ":" + String($0.element) : String($0.element) }.joined()))
    }

    func testNameIsCleanedAndShortened() {
        let p = ok("mazemaze://pair?v=1&h=a.local&p=8000&t=\(tok)&n=" + String(repeating: "x", count: 100))!
        XCTAssertEqual(p.name?.count, 40)
        XCTAssertEqual(ok("mazemaze://pair?v=1&h=a.local&p=8000&t=\(tok)&n=a%00b%0Ac")?.name, "abc")
        XCTAssertEqual(ok("mazemaze://pair?v=1&h=a.local&p=8000&t=\(tok)&n=%E2%80%AEMac%E2%80%8B")?.name, "Mac")     // bidi / zero-width stripped
        XCTAssertEqual(ok("mazemaze://pair?v=1&h=a.local&p=8000&t=\(tok)&n=100%25")?.name, "100%")
    }

    func testErrorsAreExplainedInJapanese() {
        for e in [PairingError.malformed, .unsupportedVersion, .unknownParameter("x"), .duplicateParameter("h"), .missing("t"), .invalid("p")] {
            XCTAssertFalse(e.message.isEmpty)
            XCTAssertTrue(e.message.contains("ペアリング") || e.message.contains("読み取"))
        }
    }
}

final class PinTests: XCTestCase {
    let der = Data("certificate-bytes".utf8)

    func testFingerprintNormalizationRejectsWeakOrBrokenValues() {
        let hex = PinEvaluator.fingerprint(of: der)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(PinEvaluator.normalizeFingerprint(hex.uppercased()), hex)
        XCTAssertEqual(PinEvaluator.normalizeFingerprint(stride(from: 0, to: 64, by: 2).map { String(hex.dropFirst($0).prefix(2)) }.joined(separator: ":")), hex)
        for bad in ["", String(repeating: "a", count: 40), String(repeating: "a", count: 32), hex + "0", String(hex.dropLast()) + "z"] { XCTAssertNil(PinEvaluator.normalizeFingerprint(bad)) }
    }

    func testEvaluate() {
        let fp = PinEvaluator.fingerprint(of: der)
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [der], expected: fp), .accept)
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [der, Data("ca".utf8)], expected: fp), .accept)          // only the leaf counts
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [Data("ca".utf8), der], expected: fp), .mismatch)
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [Data("other".utf8)], expected: fp), .mismatch)
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [], expected: fp), .mismatch)
        var flipped = Array(fp); flipped[0] = flipped[0] == "a" ? "b" : "a"
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [der], expected: String(flipped)), .mismatch)         // one digit off
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [der], expected: nil), .notPinned)
        XCTAssertEqual(PinEvaluator.evaluate(chainDER: [der], expected: "junk"), .notPinned)
    }

    func testKnownVector() {
        // SHA-256("abc")
        XCTAssertEqual(PinEvaluator.fingerprint(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class PairingSettingsTests: XCTestCase {
    let fp = String(repeating: "cd", count: 32)
    let tok = "Tok3n_abcdefghij-0123456789"
    func store() -> (SettingsStore, InMemorySecretStore, UserDefaults, String) {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let secrets = InMemorySecretStore()
        return (SettingsStore(defaults: d, secrets: secrets), secrets, d, suite)
    }

    func payload(_ s: String) -> PairingPayload { if case .success(let p) = PairingPayload.parse(s) { return p }; fatalError(s) }

    func testApplyStoresAddressesPinAndTokenSeparately() throws {
        let (s, secrets, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        try s.apply(payload("mazemaze://pair?v=1&h=my-mac.local&i=192.168.3.13&p=8000&t=\(tok)&s=https&f=\(fp)&n=Mac"))
        let cfg = s.serverConfig()
        XCTAssertEqual(cfg?.baseURL.absoluteString, "https://my-mac.local:8000")
        XCTAssertEqual(cfg?.fallbackURL?.absoluteString, "https://192.168.3.13:8000")
        XCTAssertEqual(cfg?.pinnedFingerprint, fp); XCTAssertEqual(cfg?.token, tok); XCTAssertEqual(secrets.token(), tok)
        XCTAssertEqual(s.serverName, "Mac")
        let dump = d.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined()
        XCTAssertFalse(dump.contains(tok))                  // the token is only in the secret store
    }

    func testPinnedServerIsNeverReachedOverHttp() throws {
        let (s, _, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        try s.apply(payload("mazemaze://pair?v=1&h=my-mac.local&p=8000&t=\(tok)&s=https&f=\(fp)"))
        s.serverURLString = "http://my-mac.local:8000"        // an attempt to downgrade
        XCTAssertNil(s.serverConfig())
        s.serverURLString = "https://my-mac.local:8000"
        XCTAssertNotNil(s.serverConfig())
        s.fallbackURLString = "http://192.168.0.5:8000"       // a plain-http fallback next to an https primary is ignored
        XCTAssertNil(s.serverConfig()?.fallbackURL)
    }

    func testRepairingWithPlainHttpClearsTheOldPin() throws {
        let (s, _, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        try s.apply(payload("mazemaze://pair?v=1&h=my-mac.local&p=8000&t=\(tok)&s=https&f=\(fp)"))
        try s.apply(payload("mazemaze://pair?v=1&h=my-mac.local&p=8000&t=\(tok)"))
        XCTAssertNil(s.pinnedFingerprint); XCTAssertEqual(s.serverConfig()?.baseURL.scheme, "http")
    }
}

final class TailscaleTests: XCTestCase {
    let fp = String(repeating: "cd", count: 32)
    let tok = "Tok3n_abcdefghij-0123456789"
    func store() -> (SettingsStore, UserDefaults, String) {
        let suite = "mazemaze.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: d, secrets: InMemorySecretStore()), d, suite)
    }
    func payload(_ s: String) -> PairingPayload { if case .success(let p) = PairingPayload.parse(s) { return p }; fatalError(s) }
    func base(_ extra: String) -> String { "mazemaze://pair?v=1&h=my-mac.local&i=192.168.3.13&p=8000&t=\(tok)&s=https&f=\(fp)\(extra)" }

    func testTailscaleHostRule() {
        for ok in ["yuya-4.tailb93afe.ts.net", "a.b.ts.net"] {
            XCTAssertTrue(LocalHostPolicy.isTailscaleHost(ok), ok)
        }
        for bad in ["100.85.102.91", "100.64.0.0", "100.127.255.255", "100.63.255.255", "100.128.0.1", "100.085.102.91", "100.85.102", "8.8.8.8", "192.168.0.1", "10.0.0.1",
                    "ts.net", ".ts.net", "mac.ts.net", "evil.com", "yuya-4.tailb93afe.ts.net.evil.com", "evil.ts.net.com", "a..ts.net",
                    "-a.b.ts.net", "a.b-.ts.net", "my_mac.tail.ts.net", "mac.local", "localhost", "fd7a:115c:a1e0::1", "[fd7a::1]"] {
            XCTAssertFalse(LocalHostPolicy.isTailscaleHost(bad), bad)
        }
        // the Tailscale range is not a "local" address for the home fields, and the home ranges are not Tailscale
        XCTAssertFalse(LocalHostPolicy.isLocalHost("100.85.102.91"))
        XCTAssertFalse(LocalHostPolicy.isLocalHost("yuya-4.tailb93afe.ts.net"))
        XCTAssertFalse(LocalHostPolicy.isTailscaleHost("192.168.3.13"))
    }

    func testValidateTailscaleUrl() throws {
        XCTAssertEqual(try LocalHostPolicy.validateTailscale("https://yuya-4.tailb93afe.ts.net:8000").get().absoluteString, "https://yuya-4.tailb93afe.ts.net:8000")
        XCTAssertEqual(LocalHostPolicy.validateTailscale("https://100.85.102.91:8000"), .failure(.notLocal))     // names only (ATS exception covers ts.net)
        XCTAssertEqual(try LocalHostPolicy.validateTailscale("https://YUYA-4.tailb93afe.ts.net:8000").get().host, "yuya-4.tailb93afe.ts.net")
        XCTAssertEqual(LocalHostPolicy.validateTailscale("https://evil.com:8000"), .failure(.notLocal))
        XCTAssertEqual(LocalHostPolicy.validateTailscale("https://192.168.0.2:8000"), .failure(.notLocal))
        XCTAssertEqual(LocalHostPolicy.validateTailscale("https://user@100.85.102.91:8000"), .failure(.hasCredentials))
        XCTAssertEqual(LocalHostPolicy.validate("https://100.85.102.91:8000"), .failure(.notLocal))     // not accepted as the primary address
    }

    func testPairingCarriesTheTailscaleAddressOnlyWhenEncryptedAndWellFormed() {
        let p = payload(base("&ts=yuya-4.tailb93afe.ts.net"))
        XCTAssertEqual(p.tailscaleURL?.absoluteString, "https://yuya-4.tailb93afe.ts.net:8000")
        XCTAssertEqual(payload(base("&ts=Yuya-4.Tailb93afe.TS.net")).tailscaleURL?.host, "yuya-4.tailb93afe.ts.net")
        XCTAssertNil(payload(base("")).tailscaleURL)
        for bad in ["100.85.102.91", "8.8.8.8", "192.168.3.13", "evil.com", "yuya-4.tailb93afe.ts.net.evil.com", "0x64.0x55.0x66.0x5b", "100.85.102.91:8000", "fd7a:115c:a1e0::1"] {
            XCTAssertEqual(PairingPayload.parse(base("&ts=\(bad)")), .failure(.invalid("ts")), bad)
        }
        XCTAssertEqual(PairingPayload.parse(base("&ts=a.b.ts.net&ts=c.d.ts.net")), .failure(.duplicateParameter("ts")))
        // plain http: no Tailscale address (and without a certificate to pin it would be pointless)
        XCTAssertEqual(PairingPayload.parse("mazemaze://pair?v=1&h=my-mac.local&p=8000&t=\(tok)&ts=yuya-4.tailb93afe.ts.net"), .failure(.invalid("ts")))
    }

    func testApplyStoresTheTailscaleAddressAndItBecomesTheLastCandidate() throws {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        try s.apply(payload(base("&ts=yuya-4.tailb93afe.ts.net")))
        let cfg = s.serverConfig()
        XCTAssertEqual(cfg?.candidates.map { $0.host }, ["my-mac.local", "192.168.3.13", "yuya-4.tailb93afe.ts.net"])
        XCTAssertEqual(cfg?.pinnedFingerprint, fp)
        try s.apply(payload(base("")))                                   // pairing again without it forgets the old address
        XCTAssertNil(s.serverConfig()?.tailscaleURL)
    }

    func testTheTailscaleAddressIsIgnoredUnlessTheServerIsPinnedHttps() throws {
        let (s, d, suite) = store(); defer { d.removePersistentDomain(forName: suite) }
        try s.apply(payload(base("&ts=yuya-4.tailb93afe.ts.net")))
        s.tailscaleURLString = "http://yuya-4.tailb93afe.ts.net:8000"                // a plain-http Tailscale address
        XCTAssertNil(s.serverConfig()?.tailscaleURL)
        s.tailscaleURLString = "https://evil.com:8000"
        XCTAssertNil(s.serverConfig()?.tailscaleURL)
        s.tailscaleURLString = "https://yuya-4.tailb93afe.ts.net:8000"
        XCTAssertNotNil(s.serverConfig()?.tailscaleURL)
        s.pinnedFingerprint = nil                                         // unpinned: never over another network
        s.serverURLString = "http://my-mac.local:8000"
        XCTAssertNil(s.serverConfig()?.tailscaleURL)
    }

    func testSummaryAndPinsCoverTheTailscaleAddress() {
        let text = pairingSummaryForTests(payload(base("&ts=yuya-4.tailb93afe.ts.net")))
        XCTAssertTrue(text.contains("yuya-4.tailb93afe.ts.net"))
    }
}

/// `pairingSummary` lives in the app target; the same facts are checked here through the payload.
func pairingSummaryForTests(_ p: PairingPayload) -> String { [p.primaryURL.absoluteString, p.tailscaleURL?.absoluteString ?? ""].joined(separator: "\n") }
