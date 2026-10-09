import Foundation

public struct ConnectionReport: Equatable, Sendable {
    public enum State: Equatable, Sendable { case ok, warning, failed }
    public var state: State
    public var message: String
    public var model: String?
}

public enum ConnectionChecker {
    /// A beginner-friendly cause and next step for a network error. Never includes URLs or bodies.
    public static func isCertificateError(_ e: URLError) -> Bool {
        [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
         .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired].contains(e.code)
    }

    /// Plain http to a server that speaks https (or the other way round) fails in confusing ways.
    public static func isProtocolMismatch(_ e: URLError) -> Bool {
        [.networkConnectionLost, .badServerResponse, .cannotParseResponse, .zeroByteResource].contains(e.code)
    }

    public static func describe(_ error: Error, scheme: String? = nil) -> String {
        let generic = "Mac に接続できません。Mac で ./scripts/run_lan.sh が動いているか、iPhone と同じ Wi-Fi か、iPhone の「設定 > Mazemaze > ローカルネットワーク」が許可されているか確認してください。"
        guard let e = error as? URLError else { return generic }
        if isCertificateError(e) { return TranslationFailure.certificateUntrusted.message }
        if scheme == "http", isProtocolMismatch(e) {
            return "Mac から正しい応答がありません。Mac が暗号化（https）で起動している可能性があります。Mac に表示された QR を iPhone の「カメラ」で読み取って、ペアリングし直してください（暗号化なしにしたいときは、Mac を MAZEMAZE_TLS=0 ./scripts/run_lan.sh で起動します）。"
        }
        switch e.code {
        case .notConnectedToInternet:
            return "ネットワークに出られません（エラー -1009）。ローカルネットワークの許可が「オフ」になっている可能性が高いです。許可ダイアログで「許可」を押した直後なら、ホームの「もう一度確認」（または設定の「保存して接続確認」）をもう一度押してください。それでも同じなら、iPhone の「設定 > Mazemaze > ローカルネットワーク」をオンにし、Wi-Fi に接続されているか確認してください。"
        case .timedOut:
            return "Mac から応答がありません（タイムアウト）。Mac がスリープしていないか、iPhone と同じ Wi-Fi か（ゲスト Wi-Fi は不可）、URL の IP アドレスが今の Mac のものか確認してください。"
        case .cannotConnectToHost:
            return "Mac に接続できませんでした（接続拒否）。Mac で ./scripts/run_lan.sh が動いているか、ポート番号（:8000）が合っているか確認してください。ローカルネットワークの許可がオフのときも、この表示になることがあります。"
        case .cannotFindHost, .dnsLookupFailed:
            return "Mac の名前（.local）が見つかりません。IP アドレスの URL（http://192.168.x.x:8000）を試してください。"
        default:
            return generic
        }
    }

    /// GET /api/status with the token. The message tells a beginner what to check next.
    public static func check(config: ServerConfig?, transport: HTTPTransport, resolver: EndpointResolver? = nil) async -> ConnectionReport {
        guard let config else {
            return ConnectionReport(state: .failed, message: "サーバーの URL が未設定、または Mac / ローカルネットワークのアドレスではありません（例: http://192.168.0.19:8000）", model: nil)
        }
        var headers = ["Accept": "application/json"]
        if let t = config.token, !t.isEmpty { headers["X-Mazemaze-Token"] = t }
        if let resolver { await resolver.invalidate() }          // a manual check looks at both addresses again
        let base = await resolver?.resolve(config) ?? config.baseURL
        let req = HTTPRequest(url: base.appendingPathComponent("api/status"), method: "GET", headers: headers, timeout: 8)
        let response: HTTPResponse
        do {
            response = try await transport.send(req)
        } catch is PinMismatchError {
            return ConnectionReport(state: .failed, message: TranslationFailure.pinMismatch.message, model: nil)
        } catch {
            return ConnectionReport(state: .failed, message: describe(error, scheme: base.scheme), model: nil)
        }
        switch response.status {
        case 200:
            guard let s = try? JSONDecoder().decode(APIDecoding.Status.self, from: response.body) else {
                return ConnectionReport(state: .failed, message: "Mazemaze のサーバーではない可能性があります（応答を読み取れません）", model: nil)
            }
            if s.ollama_reachable != true {
                return ConnectionReport(state: .warning, message: "サーバーには接続できましたが、Mac の Ollama が起動していません。", model: s.model)
            }
            if s.model_installed != true || s.model_metadata_ok != true {
                return ConnectionReport(state: .warning, message: "サーバーには接続できましたが、モデル（\(s.model ?? "?")）が使えません。Mac で ollama list を確認してください。", model: s.model)
            }
            return ConnectionReport(state: .ok, message: "接続できました（モデル: \(s.model ?? "?")\(s.busy == true ? "・処理中" : "")）", model: s.model)
        case 401:
            return ConnectionReport(state: .failed, message: "トークンが違います。Mac に表示された QR をもう一度カメラで読み取るか、Mac のターミナルに表示されたトークンを入力し直してください。", model: nil)
        case 400:
            return ConnectionReport(state: .failed, message: "この URL（ホスト名）は Mac 側で許可されていません。表示された IP アドレスの URL を使ってください。", model: nil)
        case 403:
            return ConnectionReport(state: .failed, message: "Mac 側が LAN からの接続を許可していません。./scripts/run_lan.sh で起動してください。", model: nil)
        default:
            return ConnectionReport(state: .failed, message: "サーバーがエラーを返しました（HTTP \(response.status)）", model: nil)
        }
    }
}
