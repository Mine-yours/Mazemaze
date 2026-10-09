import Foundation

public struct ConnectionReport: Equatable, Sendable {
    public enum State: Equatable, Sendable { case ok, warning, failed }
    public var state: State
    public var message: String
    public var model: String?
}

public enum ConnectionChecker {
    /// GET /api/status with the token. The message tells a beginner what to check next.
    public static func check(config: ServerConfig?, transport: HTTPTransport) async -> ConnectionReport {
        guard let config else {
            return ConnectionReport(state: .failed, message: "サーバーの URL が未設定、または Mac / ローカルネットワークのアドレスではありません（例: http://192.168.0.19:8000）", model: nil)
        }
        var headers = ["Accept": "application/json"]
        if let t = config.token, !t.isEmpty { headers["X-Mazemaze-Token"] = t }
        let req = HTTPRequest(url: config.baseURL.appendingPathComponent("api/status"), method: "GET", headers: headers, timeout: 8)
        let response: HTTPResponse
        do {
            response = try await transport.send(req)
        } catch {
            return ConnectionReport(state: .failed, message: "Mac に接続できません。Mac で ./scripts/run_lan.sh を起動しているか、同じ Wi-Fi か、iPhone の「設定 > Mazemaze > ローカルネットワーク」が許可されているか確認してください。", model: nil)
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
            return ConnectionReport(state: .failed, message: "トークンが違います。Mac のターミナルに表示されたトークンを入力してください。", model: nil)
        case 400:
            return ConnectionReport(state: .failed, message: "この URL（ホスト名）は Mac 側で許可されていません。表示された IP アドレスの URL を使ってください。", model: nil)
        case 403:
            return ConnectionReport(state: .failed, message: "Mac 側が LAN からの接続を許可していません。./scripts/run_lan.sh で起動してください。", model: nil)
        default:
            return ConnectionReport(state: .failed, message: "サーバーがエラーを返しました（HTTP \(response.status)）", model: nil)
        }
    }
}
