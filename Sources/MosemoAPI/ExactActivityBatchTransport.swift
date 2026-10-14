import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Keeps generated routing/response decoding while replaying the encrypted, persisted request bytes.
struct ExactActivityBatchTransport: ClientTransport {
    let underlying: any ClientTransport
    let body: Data
    let now: @Sendable () -> Date

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == Operations.ActivitiesAcceptBatch.id else {
            return try await underlying.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        var request = request
        request.headerFields[.contentLength] = String(self.body.count)
        let response = try await underlying.send(request, body: HTTPBody(self.body), baseURL: baseURL, operationID: operationID)
        let status = response.0.status.code
        if status == 408 || status == 429 || (500...599).contains(status) {
            let value = response.0.headerFields[HTTPField.Name("Retry-After")!]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let delay: TimeInterval?
            if let value, let seconds = TimeInterval(value), seconds >= 0 {
                delay = seconds
            } else if let value {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                delay = formatter.date(from: value).map { max(0, $0.timeIntervalSince(now())) }
            } else { delay = nil }
            throw MosemoAPIError.retryableServerError(statusCode: status, retryAfter: delay)
        }
        return response
    }
}
