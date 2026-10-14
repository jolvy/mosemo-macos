import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import MosemoAPI

final class TimelineAuthenticationRaceTests: XCTestCase {
    func testDelayedUnauthorizedTimelineCannotDeleteNewAuthenticationToken() async throws {
        let now = Date()
        let oldToken = StoredAccessToken(value: "old-test-only", expiresAt: now.addingTimeInterval(3600))
        let newToken = StoredAccessToken(value: "new-test-only", expiresAt: now.addingTimeInterval(3600))
        let store = RaceTokenStore(token: oldToken)
        let transport = DelayedTimelineUnauthorizedTransport()
        let baseURL = URL(string: "https://test.invalid")!
        let generated = Client(serverURL: baseURL, transport: transport,
            middlewares: [BearerAuthenticationMiddleware(tokenStore: store, now: { now })])
        let client = LiveMosemoAPIClient(baseURL: baseURL, anonymousClient: generated,
            authenticatedClient: generated, tokenStore: store, now: { now })

        let request = Task {
            try await client.fetch(day: .init(year: 2026, month: 10, day: 15), timeZoneID: "UTC")
        }
        await transport.waitUntilEntered()
        let authorization = await transport.authorization
        XCTAssertEqual(authorization, "Bearer old-test-only")
        try await store.save(newToken)
        await transport.release()
        do {
            _ = try await request.value
            XCTFail("Expected the old request's authentication failure")
        } catch {
            XCTAssertEqual(error as? MosemoAPIError, .authenticationRequired)
        }
        let tokenAfterOldResponse = try await store.load()
        XCTAssertEqual(tokenAfterOldResponse, newToken)
    }
}

private actor RaceTokenStore: AccessTokenStoring {
    private var token: StoredAccessToken?
    init(token: StoredAccessToken) { self.token = token }
    func load() async throws -> StoredAccessToken? { token }
    func save(_ token: StoredAccessToken) async throws { self.token = token }
    func delete() async throws { token = nil }
}

/// Controlled delayed HTTP response, not an external authentication service.
private actor DelayedTimelineUnauthorizedTransport: ClientTransport {
    private var started = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseGate: CheckedContinuation<Void, Never>?
    private(set) var authorization: String?

    func waitUntilEntered() async {
        if started { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        responseGate?.resume()
        responseGate = nil
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL,
              operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        authorization = request.headerFields[.authorization]
        started = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { responseGate = $0 }
        let data = Data(#"{"error":{"code":401,"status":"AUTH_INVALID_ACCESS_TOKEN","message":"expired","details":[]}}"#.utf8)
        return (HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]), HTTPBody(data))
    }
}
