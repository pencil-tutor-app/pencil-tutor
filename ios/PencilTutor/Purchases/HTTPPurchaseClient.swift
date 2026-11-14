import Foundation

/// POST /api/purchase. The only call the app makes without a student code: Apple's signed transaction is the credential.
/// Logs host-free facts only (status, sizes, latency). Never the signed transaction and never the code in the reply.
struct HTTPPurchaseClient: PurchaseRedeeming {
    let baseURL: URL
    let log: SessionLog

    func redeem(signedTransaction: String) async throws -> PurchaseReply {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/purchase"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(["signed_transaction": signedTransaction])
        request.httpBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        let started = Date()
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            log.record("http_failed", ["path": "api/purchase", "request_bytes": body.count,
                                       "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000), "url_error_code": error.code.rawValue])
            throw PurchaseError.offline
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw PurchaseError.badReply }
        log.record("http_reply", ["path": "api/purchase", "status": http.statusCode, "request_bytes": body.count,
                                  "response_bytes": data.count, "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)])

        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: try? JSONDecoder().decode(ServerErrorBody.self, from: data))
        }
        do {
            return try JSONDecoder().decode(PurchaseReply.self, from: data)
        } catch {
            throw PurchaseError.badReply
        }
    }

    /// Turns a non-2xx reply into a `PurchaseError`. Pure, so it is unit-tested.
    static func error(status: Int, body: ServerErrorBody?) -> PurchaseError {
        let reason = body?.reason ?? body?.error ?? "no reason given"
        if status == 403, body?.error == "subscription_not_active" { return .notActive }
        if status >= 500 { return .unavailable(reason: reason) }
        return .rejected(reason: reason)
    }
}
