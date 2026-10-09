import Foundation

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
/// another host), uses no cookies/cache, and does not log request or response bodies.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

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

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        req.httpMethod = request.method
        req.httpBody = request.body
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
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
}
