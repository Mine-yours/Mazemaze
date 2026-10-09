import Foundation
import Security

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]   // lower-cased names
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession-based transport. Never follows redirects (a redirect would carry the token to
/// another host), uses no cookies/cache, and does not log request or response bodies. For hosts that
/// have a pinned certificate fingerprint it accepts exactly that certificate (and no other) and
/// refuses before any request is sent if the server presents a different one.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let lock = NSLock()
    private var pins: [String: String] = [:]          // host -> sha256 fingerprint
    private var mismatchedHosts: Set<String> = []

    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Hosts (lowercase) and the certificate fingerprint each must present.
    public func setPins(_ newPins: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        pins = Dictionary(uniqueKeysWithValues: newPins.compactMap { k, v in PinEvaluator.normalizeFingerprint(v).map { (k.lowercased(), $0) } })
    }

    private func pin(for host: String) -> String? { lock.lock(); defer { lock.unlock() }; return pins[host.lowercased()] }
    private func noteMismatch(_ host: String) { lock.lock(); mismatchedHosts.insert(host.lowercased()); lock.unlock() }
    private func takeMismatch(_ host: String) -> Bool { lock.lock(); defer { lock.unlock() }; return mismatchedHosts.remove(host.lowercased()) != nil }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        req.httpMethod = request.method
        req.httpBody = request.body
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if let host = request.url.host, takeMismatch(host) { throw PinMismatchError() }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              let expected = pin(for: space.host) else {
            completionHandler(.performDefaultHandling, nil)      // not a pinned server: normal system checks
            return
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let der = chain.map { SecCertificateCopyData($0) as Data }
        switch PinEvaluator.evaluate(chainDER: der, expected: expected) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .mismatch, .notPinned:
            noteMismatch(space.host)
            completionHandler(.cancelAuthenticationChallenge, nil)   // nothing (no token, no text) is sent
        }
    }
}
