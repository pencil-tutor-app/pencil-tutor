import Foundation

/// Reads the server address and access token from Info.plist, which gets them from `Config/Secrets.xcconfig`.
struct AppConfig {
    let serverURL: URL?
    let accessToken: String?
    /// Plain reason when the app cannot talk to the server. Nil when it can.
    let missingReason: String?

    static func load(bundle: Bundle = .main) -> AppConfig {
        let rawURL = (bundle.object(forInfoDictionaryKey: "SERVER_URL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let rawToken = (bundle.object(forInfoDictionaryKey: "APP_ACCESS_TOKEN") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""

        guard !rawURL.isEmpty, !rawURL.hasPrefix("$("), let url = URL(string: rawURL), let host = url.host, !host.isEmpty else {
            return AppConfig(serverURL: nil, accessToken: nil, missingReason: "SERVER_URL is not set in ios/Config/Secrets.xcconfig")
        }
        if host.hasSuffix(".invalid") {
            return AppConfig(serverURL: nil, accessToken: nil, missingReason: "SERVER_URL is still the example placeholder (\(host))")
        }
        if rawToken.isEmpty || rawToken.hasPrefix("$(") || rawToken == "replace-me" {
            return AppConfig(serverURL: nil, accessToken: nil, missingReason: "APP_ACCESS_TOKEN is not set in ios/Config/Secrets.xcconfig")
        }
        return AppConfig(serverURL: url, accessToken: rawToken, missingReason: nil)
    }
}

/// Talks to the real server over HTTPS. Logs host, path, sizes, status and latency. Never logs the token or bodies.
final class HTTPTutorClient: TutorClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let log: SessionLog

    init(baseURL: URL, token: String, log: SessionLog) {
        self.baseURL = baseURL
        self.token = token
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

    private func post<Body: Encodable, Reply: Decodable>(path: String, body: Body, timeout: TimeInterval) async throws -> Reply {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let payload = try JSONEncoder().encode(body)
        urlRequest.httpBody = payload

        let started = Date()
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: urlRequest)
        } catch let error as URLError {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.record("http_failed", ["path": path, "request_bytes": payload.count, "elapsed_ms": ms, "url_error_code": error.code.rawValue])
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
        log.record("http_reply", ["path": path, "status": http.statusCode, "request_bytes": payload.count, "response_bytes": data.count, "elapsed_ms": ms])

        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
            let reason = body?.reason ?? body?.error ?? "no reason given"
            switch http.statusCode {
            case 401: throw TutorError.unauthorized
            case 503: throw TutorError.serverUnavailable(status: 503, reason: reason)
            case 500...599: throw TutorError.serverUnavailable(status: http.statusCode, reason: reason)
            default: throw TutorError.rejected(status: http.statusCode, reason: reason)
            }
        }
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw TutorError.badResponse(detail: "\(path) reply did not match the contract: \(error)")
        }
    }
}
