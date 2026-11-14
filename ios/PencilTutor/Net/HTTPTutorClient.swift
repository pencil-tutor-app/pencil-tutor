import Foundation

/// Reads the server address from Info.plist, which gets it from `Config/Secrets.xcconfig`. There is no shared access token
/// any more: each student's code is the credential (see `StudentCode`), so nothing secret ships in the app.
struct AppConfig {
    let serverURL: URL?
    /// Plain reason when the app cannot talk to the server. Nil when it can.
    let missingReason: String?

    static func load(bundle: Bundle = .main) -> AppConfig {
        let rawURL = (bundle.object(forInfoDictionaryKey: "SERVER_URL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""

        guard !rawURL.isEmpty, !rawURL.hasPrefix("$("), let url = URL(string: rawURL), let host = url.host, !host.isEmpty else {
            return AppConfig(serverURL: nil, missingReason: "SERVER_URL is not set in ios/Config/Secrets.xcconfig")
        }
        if host.hasSuffix(".invalid") {
            return AppConfig(serverURL: nil, missingReason: "SERVER_URL is still the example placeholder (\(host))")
        }
        return AppConfig(serverURL: url, missingReason: nil)
    }
}

/// Talks to the real server over HTTPS. Logs host, path, sizes, status and latency. Never logs the code or bodies.
/// The bearer is the student's code, read from `codeHolder` on every request.
final class HTTPTutorClient: TutorClient {
    private let baseURL: URL
    private let codeHolder: StudentCodeHolder
    private let session: URLSession
    private let log: SessionLog

    init(baseURL: URL, codeHolder: StudentCodeHolder, log: SessionLog) {
        self.baseURL = baseURL
        self.codeHolder = codeHolder
        self.log = log
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func watch(_ request: WatchRequest) async throws -> WatchResponse {
        try await post(path: "api/watch", body: request, timeout: 40)
    }

    func ask(_ request: AskRequest) async throws -> AskResponse {
        try await post(path: "api/ask", body: request, timeout: 60)
    }

    func consult(_ request: ConsultRequest) async throws -> ConsultResponse {
        try await post(path: "api/consult", body: request, timeout: 40)
    }

    func createLiveSession(_ request: LiveSessionRequest) async throws -> LiveSessionResponse {
        try await post(path: "api/live-session", body: request, timeout: 20)
    }

    func me() async throws -> MeResponse {
        try await send(path: "api/me", method: "GET", payload: nil, timeout: 15)
    }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        try await post(path: "api/heartbeat", body: request, timeout: 15)
    }

    func memoryStatus() async throws -> MemoryStatusResponse {
        try await send(path: "api/memory", method: "GET", payload: nil, timeout: 15)
    }

    func memoryAct(_ request: MemoryActionRequest) async throws -> MemoryActionResponse {
        try await post(path: "api/memory", body: request, timeout: 20)
    }

    private func post<Body: Encodable, Reply: Decodable>(path: String, body: Body, timeout: TimeInterval) async throws -> Reply {
        try await send(path: path, method: "POST", payload: try JSONEncoder().encode(body), timeout: timeout)
    }

    private func send<Reply: Decodable>(path: String, method: String, payload: Data?, timeout: TimeInterval) async throws -> Reply {
        guard let code = codeHolder.current else {
            log.record("http_not_sent", ["path": path, "reason": "no_student_code"])
            throw TutorError.unauthorized(reason: "no_code")
        }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        if let payload {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = payload
        }
        let requestBytes = payload?.count ?? 0

        let started = Date()
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: urlRequest)
        } catch let error as URLError {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.record("http_failed", ["path": path, "request_bytes": requestBytes, "elapsed_ms": ms, "url_error_code": error.code.rawValue])
            switch error.code {
            case .timedOut:
                throw TutorError.timedOut
            default:
                throw TutorError.offline(detail: "\(path) URLError \(error.code.rawValue)")
            }
        }

        let (data, response) = result
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse else {
            throw TutorError.badResponse(detail: "\(path) did not return an HTTP response")
        }
        log.record("http_reply", ["path": path, "status": http.statusCode, "request_bytes": requestBytes, "response_bytes": data.count, "elapsed_ms": ms])

        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
            throw Self.error(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw TutorError.badResponse(detail: "\(path) reply did not match the contract: \(error)")
        }
    }

    /// Turns a non-2xx reply into the typed error the rest of the app understands. Pure, so it is unit-tested.
    static func error(status: Int, body: ServerErrorBody?) -> TutorError {
        let reason = body?.reason ?? body?.error ?? "no reason given"
        switch status {
        case 401:
            return .unauthorized(reason: body?.reason ?? "unknown")
        case 403:
            switch body?.error {
            case "code_disabled": return .codeTurnedOff
            case "hours_used_up": return .hoursUsedUp(allowance: body?.allowance)
            case "live_not_in_plan": return .liveNotInPlan
            default: return .rejected(status: status, reason: reason)
            }
        case 503:
            return .serverUnavailable(status: 503, reason: reason)
        case 500...599:
            return .serverUnavailable(status: status, reason: reason)
        default:
            return .rejected(status: status, reason: reason)
        }
    }
}
