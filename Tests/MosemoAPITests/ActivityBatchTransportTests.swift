import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import XCTest
@testable import MosemoAPI

final class ActivityBatchTransportTests: XCTestCase {
    func testGenerated202RouteReplaysExactPersistedBodyAndBearerWithoutInventedReceivedAt() async throws {
        let batch = try await makeBatch()
        let transport = BatchWireStub(status: 202, response: Data("{\"batchId\":\"\(batch.id)\",\"status\":\"accepted\"}".utf8))
        let client = makeClient(transport)
        let result = try await client.createActivityBatch(batch)
        XCTAssertEqual(result.batchID, batch.id)
        let sent = await transport.request
        let body = await transport.body
        XCTAssertEqual(sent?.path, "/api/v1/activities/batches")
        XCTAssertEqual(sent?.headerFields[.authorization], "Bearer test-only")
        XCTAssertEqual(body, batch.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        XCTAssertNil(json["accountId"])
        XCTAssertNil((json["records"] as? [[String: Any]])?.first?["deviceId"])
    }

    func testExplicitPreDelivery413IsDistinctFromUnknown413AndRetryAfterSurvivesTypedClient() async throws {
        let batch = try await makeBatch()
        for (status, body, expected) in [
            (413, #"{"error":{"code":413,"status":"ACTIVITY_BATCH_TOO_LARGE","message":"large","details":[]}}"#, MosemoAPIError.activityBatchRejectedTooLarge),
            (413, #"{"error":{"code":413,"status":"UNKNOWN","message":"large","details":[]}}"#, .unexpectedResponse(statusCode: 413)),
            (503, "{}", .retryableServerError(statusCode: 503, retryAfter: 7)),
            (202, "{\"batchId\":\"\(UUID())\",\"status\":\"accepted\"}", .unexpectedResponse(statusCode: 202)),
            (202, "{\"batchId\":\"\(batch.id)\",\"status\":\"stored\"}", .unexpectedResponse(statusCode: 202))
        ] {
            let transport = BatchWireStub(status: status, response: Data(body.utf8), retryAfter: "7")
            do { _ = try await makeClient(transport).createActivityBatch(batch); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? MosemoAPIError, expected) }
        }
    }

    func testBatchSessionHasWholeResourceDeadlineOf15Seconds() {
        let configuration = LiveMosemoAPIClient.batchSessionConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForResource, 15)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertNil(configuration.urlCache)
    }

    func test15SecondResourceDeadlineIncludesStalledResponseBody() async throws {
        let batch = try await makeBatch()
        let configuration = LiveMosemoAPIClient.batchSessionConfiguration()
        configuration.protocolClasses = [StalledBatchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = makeClient(URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered)))
        let completed = expectation(description: "Whole response resource deadline")
        let start = Date()
        let task = Task {
            do { _ = try await client.createActivityBatch(batch); XCTFail("A partial JSON body must not succeed") }
            catch { XCTAssertEqual(error as? MosemoAPIError, .timedOut) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 20)
        task.cancel()
        let duration = Date().timeIntervalSince(start)
        // The contract is a maximum resource deadline, not a minimum wait.
        // Foundation may fail earlier; verify timeout (above) and the upper bound.
        // A small scheduling allowance avoids requiring an exact timer firing instant.
        XCTAssertLessThanOrEqual(duration, 16)
    }

    private func makeClient(_ transport: any ClientTransport) -> LiveMosemoAPIClient {
        let baseURL = URL(string: "https://test.invalid")!
        let store = BatchWireTokenStore()
        let plain = Client(serverURL: baseURL, transport: transport)
        return LiveMosemoAPIClient(baseURL: baseURL, anonymousClient: plain, authenticatedClient: plain,
            tokenStore: store, now: { .now }, batchClient: { body in
                Client(serverURL: baseURL, configuration: .init(dateTranscoder: MosemoDateTranscoder()),
                    transport: ExactActivityBatchTransport(underlying: transport, body: body, now: { .now }),
                    middlewares: [BearerAuthenticationMiddleware(tokenStore: store, now: { .now })])
            })
    }

    private func makeBatch() async throws -> ActivityBatch {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: BatchWireKey())
        let account = UUID(), device = UUID()
        _ = try await queue.enqueue(accountID: account, deviceID: device, observedAt: .now,
            timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { .observation(.init(metadata: $0, context: .opaque)) }
        let prepared = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: .now, drainBacklog: true)
        guard case .ready(let batch) = prepared else { throw MosemoAPIError.activityQueueStorageFailed }
        return batch
    }
}

// A controlled HTTP transport test double; no live server is contacted.
private actor BatchWireStub: ClientTransport {
    let status: Int
    let response: Data
    let retryAfter: String?
    private(set) var request: HTTPRequest?
    private(set) var body: Data?
    init(status: Int, response: Data, retryAfter: String? = nil) { self.status = status; self.response = response; self.retryAfter = retryAfter }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        self.request = request
        if let body { self.body = try await Data(collecting: body, upTo: 512 * 1024) } else { self.body = nil }
        var fields: HTTPFields = [.contentType: "application/json"]
        fields[HTTPField.Name("Retry-After")!] = retryAfter
        return (HTTPResponse(status: .init(code: status), headerFields: fields), HTTPBody(response))
    }
}
private struct BatchWireKey: ActivityQueueKeyStoring { func loadOrCreateKey() async throws -> Data { Data(repeating: 5, count: 32) } }
private actor BatchWireTokenStore: AccessTokenStoring {
    func load() -> StoredAccessToken? { .init(value: "test-only", expiresAt: .distantFuture) }
    func save(_ token: StoredAccessToken) {}
    func delete() {}
}

// URLProtocol is an HTTP test double: it sends headers plus a partial response and never finishes.
private final class StalledBatchURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{".utf8))
    }
    override func stopLoading() {}
}
