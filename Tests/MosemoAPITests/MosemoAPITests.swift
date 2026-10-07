import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import XCTest
@testable import MosemoAPI

final class MosemoAPITests: XCTestCase {
    private let baseURL = URL(string: "https://api.mosemo.test")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAuthenticateStoresTokenAndMapsAccount() async throws {
        let tokenStore = MemoryAccessTokenStore()
        let accountID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let authenticatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let client = makeClient(
            tokenStore: tokenStore,
            exchange: { _ in
                .ok(.init(body: .json(.init(
                    accessToken: "test-access-token",
                    expiresIn: 3_600
                ))))
            },
            getMe: { _ in
                .ok(.init(body: .json(.init(
                    accountId: accountID.uuidString,
                    createdAt: createdAt,
                    lastAuthenticatedAt: authenticatedAt,
                    provider: .kakao,
                    timezone: .asiaSeoul
                ))))
            }
        )

        let account = try await client.authenticate(
            authorizationCode: "one-time-code",
            codeVerifier: String(repeating: "a", count: 43)
        )

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.provider, .kakao)
        XCTAssertEqual(account.timeZoneID, "Asia/Seoul")
        XCTAssertEqual(account.createdAt, createdAt)
        XCTAssertEqual(account.lastAuthenticatedAt, authenticatedAt)
        let storedToken = await tokenStore.currentToken()
        XCTAssertEqual(storedToken?.value, "test-access-token")
        XCTAssertEqual(storedToken?.expiresAt, now.addingTimeInterval(3_600))
    }

    func testAuthenticateMapsBadRequestWithoutInspectingDetail() async {
        let client = makeClient(exchange: { _ in
            .badRequest(.init(body: .json(makeErrorResponse(
                code: 400,
                status: "AUTH_INVALID_CODE",
                message: "changed message"
            ))))
        })

        await assertAPIError(.invalidAuthorizationCode) {
            _ = try await client.authenticate(
                authorizationCode: "invalid",
                codeVerifier: String(repeating: "a", count: 43)
            )
        }
    }

    func testAuthenticateMapsValidationFailure() async {
        let client = makeClient(exchange: { _ in
            .unprocessableContent(.init(body: .json(makeErrorResponse(
                code: 422,
                status: "VALIDATION_ERROR",
                message: "validation failed"
            ))))
        })

        await assertAPIError(.validationFailed) {
            _ = try await client.authenticate(
                authorizationCode: "invalid",
                codeVerifier: "invalid"
            )
        }
    }

    func testAuthenticateMapsMalformedBadRequestByStatus() async {
        let client = makeClient(exchange: { input in
            throw ClientError(
                operationID: "authExchangeToken",
                operationInput: input,
                response: HTTPResponse(status: .badRequest),
                causeDescription: "malformed error body",
                underlyingError: TestTransportError()
            )
        })

        await assertAPIError(.invalidAuthorizationCode) {
            _ = try await client.authenticate(
                authorizationCode: "invalid",
                codeVerifier: String(repeating: "a", count: 43)
            )
        }
    }

    func testCurrentAccountClearsTokenOnUnauthorized() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "expired-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let client = makeClient(
            tokenStore: tokenStore,
            getMe: { _ in
                .unauthorized(.init(body: .json(makeErrorResponse(
                    code: 401,
                    status: "AUTH_INVALID_ACCESS_TOKEN",
                    message: "unauthorized"
                ))))
            }
        )

        await assertAPIError(.authenticationRequired) {
            _ = try await client.currentAccount()
        }
        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testCurrentAccountClearsTokenOnMalformedUnauthorizedResponse() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "stored-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let client = makeClient(
            tokenStore: tokenStore,
            getMe: { input in
                throw ClientError(
                    operationID: "accountsGetMe",
                    operationInput: input,
                    response: HTTPResponse(status: .unauthorized),
                    causeDescription: "malformed error body",
                    underlyingError: TestTransportError()
                )
            }
        )

        await assertAPIError(.authenticationRequired) {
            _ = try await client.currentAccount()
        }
        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testTimelineRequestMapsServerOrderAndOpenSegments() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "timeline-token", expiresAt: now.addingTimeInterval(60)
        ))
        let recorder = RequestRecorder()
        let response = Data(#"""
        [
          {
            "itemType": "activity_group",
            "groupVersion": "g1",
            "startedAt": "2026-09-14T00:00:00.123456Z",
            "endedAt": "2026-09-14T00:00:00.123456Z",
            "state": "confirmed",
            "selection": {
              "kind": "label",
              "labelId": "22222222-2222-2222-2222-222222222222",
              "displayName": "코딩"
            },
            "segments": [
              {
                "segmentId": "00000000-0000-0000-0000-000000000001",
                "startedAt": "2026-09-14T00:00:00.123456Z",
                "endedAt": "2026-09-14T00:00:00.123456Z",
                "lastObservedAt": "2026-09-14T00:00:00.123456Z",
                "context": {
                  "kind": "detailed",
                  "app": {
                    "bundleId": {
                      "status": "captured",
                      "value": "com.apple.Safari"
                    },
                    "name": {
                      "status": "captured",
                      "value": "Safari"
                    }
                  },
                  "window": {
                    "status": "captured",
                    "title": {
                      "status": "captured",
                      "value": "Window",
                      "truncated": false
                    }
                  },
                  "web": {
                    "kind": "browser",
                    "tabTitle": {
                      "status": "captured",
                      "value": "Tab",
                      "truncated": false
                    },
                    "url": {
                      "status": "captured",
                      "value": "https://example.com/path"
                    }
                  }
                },
                "segmentVersion": "v1"
              }
            ]
          },
          {
            "segmentId": "00000000-0000-0000-0000-000000000002",
            "startedAt": "2026-09-14T00:00:00Z",
            "endedAt": null,
            "lastObservedAt": "2026-09-14T00:00:01Z",
            "context": {
              "kind": "opaque"
            },
            "itemType": "opaque_activity"
          },
          {
            "segmentId": "00000000-0000-0000-0000-000000000003",
            "startedAt": "2026-09-14T00:00:01Z",
            "endedAt": null,
            "reason": "screen_locked",
            "itemType": "capture_gap"
          },
          {
            "segmentId": "00000000-0000-0000-0000-000000000004",
            "startedAt": "2026-09-14T00:00:02Z",
            "endedAt": null,
            "lastObservedAt": "2026-09-14T00:00:02Z",
            "context": {
              "kind": "detailed",
              "app": {
                "bundleId": {
                  "status": "absent"
                },
                "name": {
                  "status": "unavailable",
                  "reason": "permission"
                }
              },
              "window": {
                "status": "absent"
              },
              "web": {
                "kind": "not_applicable"
              }
            },
            "itemType": "in_progress_activity"
          }
        ]
        """#.utf8)
        let transport = RecordingClientTransport { request, body, baseURL, operationID in
            await recorder.record(request: request, hasBody: body != nil, baseURL: baseURL, operationID: operationID)
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)
        let requested = TimelineDate(year: 2026, month: 9, day: 14)

        let day = try await client.fetch(day: requested, timeZoneID: "America/New_York")

        XCTAssertEqual(day.date, requested)
        XCTAssertEqual(day.timeZoneID, "America/New_York")
        XCTAssertEqual(day.segments.map(\.id.uuidString), (1...4).map { String(format: "00000000-0000-0000-0000-%012d", $0) })
        guard case .activity(let detailed) = day.segments[0],
              case .detailed(let context) = detailed.context else { return XCTFail("Expected detailed activity") }
        XCTAssertEqual(detailed.startedAt, detailed.endedAt)
        XCTAssertEqual(detailed.confirmedLabel, .label(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, displayName: "코딩"))
        XCTAssertEqual(context.appName, "Safari")
        XCTAssertEqual(context.windowTitle, "Window")
        XCTAssertEqual(context.tabTitle, "Tab")
        XCTAssertEqual(context.webURL, "https://example.com/path")
        guard case .activity(let opaque) = day.segments[1],
              case .opaque = opaque.context else { return XCTFail("Expected opaque activity") }
        XCTAssertNil(opaque.endedAt)
        XCTAssertGreaterThan(opaque.lastObservedAt, opaque.startedAt)
        guard case .captureGap(let gap) = day.segments[2] else { return XCTFail("Expected gap") }
        XCTAssertNil(gap.endedAt)
        XCTAssertEqual(gap.reason, "screen_locked")
        guard case .activity(let unknown) = day.segments[3],
              case .detailed(let unknownContext) = unknown.context else { return XCTFail("Expected detail with missing fields") }
        XCTAssertNil(unknownContext.appName)

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].request.method, .get)
        XCTAssertEqual(requests[0].request.path, "/api/v1/activities/label-timeline?date=2026-09-14")
        XCTAssertEqual(requests[0].request.headerFields[.authorization], "Bearer timeline-token")
        XCTAssertFalse(requests[0].hasBody)
        XCTAssertEqual(requests[0].operationID, "activitiesGetLabelTimeline")
    }

    func testTimelineEmptyResponseIsAnEmptyServerDay() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "timeline-token", expiresAt: now.addingTimeInterval(60)
        ))
        let transport = RecordingClientTransport { _, _, _, _ in
            (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(Data("[]".utf8)))
        }
        let day = try await makeTransportClient(tokenStore: tokenStore, transport: transport)
            .fetch(day: .init(year: 2026, month: 9, day: 14), timeZoneID: "UTC")
        XCTAssertTrue(day.segments.isEmpty)
        XCTAssertEqual(day.timeZoneID, "UTC")
    }

    func testTimelineUnauthorizedClearsToken() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "timeline-token", expiresAt: now.addingTimeInterval(60)
        ))
        let response = Data(#"{"error":{"code":401,"status":"AUTH_INVALID_ACCESS_TOKEN","message":"expired","details":[]}}"#.utf8)
        let transport = RecordingClientTransport { _, _, _, _ in
            (HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]), HTTPBody(response))
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)

        await assertAPIError(.authenticationRequired) {
            try await client.fetch(day: .init(year: 2026, month: 9, day: 14), timeZoneID: "UTC")
        }
        let token = await tokenStore.currentToken()
        XCTAssertNil(token)
    }

    func testTimelineServerAndTransportFailuresKeepToken() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "timeline-token", expiresAt: now.addingTimeInterval(60)
        ))
        let serverResponse = Data(#"{"error":{"code":500,"status":"INTERNAL_SERVER_ERROR","message":"error","details":[]}}"#.utf8)
        let serverTransport = RecordingClientTransport { _, _, _, _ in
            (HTTPResponse(status: .internalServerError, headerFields: [.contentType: "application/json"]), HTTPBody(serverResponse))
        }
        let networkTransport = RecordingClientTransport { _, _, _, _ in
            throw URLError(.notConnectedToInternet)
        }

        await assertAPIError(.serverError(statusCode: 500)) {
            try await makeTransportClient(tokenStore: tokenStore, transport: serverTransport)
                .fetch(day: .init(year: 2026, month: 9, day: 14), timeZoneID: "UTC")
        }
        await assertAPIError(.networkUnavailable) {
            try await makeTransportClient(tokenStore: tokenStore, transport: networkTransport)
                .fetch(day: .init(year: 2026, month: 9, day: 14), timeZoneID: "UTC")
        }
        let token = await tokenStore.currentToken()
        XCTAssertEqual(token?.value, "timeline-token")
    }

    func testTimelineAgainstLocalServerWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["MOSEMO_TIMELINE_TEST_URL"],
              let baseURL = URL(string: urlString),
              let tokenPath = environment["MOSEMO_TIMELINE_TEST_TOKEN_FILE"],
              let dateString = environment["MOSEMO_TIMELINE_TEST_DATE"] else {
            throw XCTSkip("Set local server URL, token file and date for HTTP verification")
        }
        let components = dateString.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return XCTFail("Expected YYYY-MM-DD date") }
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: token, expiresAt: Date().addingTimeInterval(3600)
        ))
        let transport = URLSessionTransport(configuration: .init(
            session: URLSession(configuration: .ephemeral)
        ))
        let client = LiveMosemoAPIClient(
            baseURL: baseURL,
            anonymousClient: Client(serverURL: baseURL, configuration: .init(dateTranscoder: MosemoDateTranscoder()), transport: transport),
            authenticatedClient: Client(
                serverURL: baseURL,
                configuration: .init(dateTranscoder: MosemoDateTranscoder()),
                transport: transport,
                middlewares: [BearerAuthenticationMiddleware(tokenStore: tokenStore, now: { Date() })]
            ),
            tokenStore: tokenStore,
            now: { Date() }
        )
        let account = try await client.currentAccount()
        let requested = TimelineDate(year: components[0], month: components[1], day: components[2])
        do {
            let generated = Client(serverURL: baseURL, configuration: .init(dateTranscoder: MosemoDateTranscoder()), transport: transport, middlewares: [
                BearerAuthenticationMiddleware(tokenStore: tokenStore, now: { Date() })
            ])
            let output = try await generated.activitiesGetLabelTimeline(query: .init(date: requested.description))
            _ = try output.ok.body.json
        } catch {
            XCTFail("Generated timeline decoding failed: \(error)")
        }
        let day = try await client.fetch(day: requested, timeZoneID: account.timeZoneID)

        XCTAssertEqual(day.date, requested)
        XCTAssertEqual(day.timeZoneID, account.timeZoneID)
        XCTAssertFalse(day.segments.isEmpty)
        if let expectedID = environment["MOSEMO_TIMELINE_TEST_SEGMENT_ID"] {
            XCTAssertTrue(day.segments.contains { $0.id.uuidString.lowercased() == expectedID.lowercased() })
        }
    }

    func testRegisterDeviceMapsCreatedResponse() async throws {
        let deviceID = UUID(
            uuidString: "01890F8E-7B5A-7CC0-98C7-8F3E12345678"
        )!
        let client = makeClient(devicesCreate: { _ in
            .created(.init(body: .json(.init(deviceId: deviceID.uuidString))))
        })

        let device = try await client.registerDevice(idempotencyKey: UUID())

        XCTAssertEqual(device, Device(id: deviceID))
    }

    func testRegisterDeviceRejectsInvalidDeviceID() async {
        for id in [
            "not-a-uuid",
            "550E8400-E29B-41D4-A716-446655440000",
        ] {
            let client = makeClient(devicesCreate: { _ in
                .created(.init(body: .json(.init(deviceId: id))))
            })

            await assertAPIError(.unexpectedResponse(statusCode: 201)) {
                _ = try await client.registerDevice(idempotencyKey: UUID())
            }
        }
    }

    func testRegisterDeviceRejectsMalformedCreatedResponse() async {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "registration-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        for data in [Data(), Data("{}".utf8), Data(#"{"deviceId":12}"#.utf8)] {
            let transport = RecordingClientTransport { _, _, _, _ in
                (
                    HTTPResponse(
                        status: .created,
                        headerFields: [.contentType: "application/json"]
                    ),
                    HTTPBody(data)
                )
            }
            let client = makeTransportClient(tokenStore: tokenStore, transport: transport)

            await assertAPIError(.unexpectedResponse(statusCode: 201)) {
                _ = try await client.registerDevice(idempotencyKey: UUID())
            }
        }
    }

    func testRegisterDeviceClearsTokenOnUnauthorized() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "invalid-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let client = makeClient(
            tokenStore: tokenStore,
            devicesCreate: { _ in
                .unauthorized(.init(body: .json(makeErrorResponse(
                    code: 401,
                    status: "AUTH_INVALID_ACCESS_TOKEN",
                    message: "expired"
                ))))
            }
        )

        await assertAPIError(.authenticationRequired) {
            _ = try await client.registerDevice(idempotencyKey: UUID())
        }

        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testRegisterDeviceClearsTokenOnMalformedUnauthorizedResponse() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "invalid-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let transport = RecordingClientTransport { _, _, _, _ in
            (
                HTTPResponse(
                    status: .unauthorized,
                    headerFields: [.contentType: "application/json"]
                ),
                HTTPBody(Data("{}".utf8))
            )
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)

        await assertAPIError(.authenticationRequired) {
            _ = try await client.registerDevice(idempotencyKey: UUID())
        }

        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testRegisterDeviceMapsValidationFailure() async {
        let client = makeClient(devicesCreate: { _ in
            .unprocessableContent(.init(body: .json(makeErrorResponse(
                code: 422,
                status: "INVALID_ARGUMENT",
                message: "invalid key"
            ))))
        })

        await assertAPIError(.validationFailed) {
            _ = try await client.registerDevice(idempotencyKey: UUID())
        }
    }

    func testRegisterDeviceMapsMalformedValidationFailure() async {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "registration-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let transport = RecordingClientTransport { _, _, _, _ in
            (
                HTTPResponse(
                    status: .unprocessableContent,
                    headerFields: [.contentType: "application/json"]
                ),
                HTTPBody(Data("{}".utf8))
            )
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)

        await assertAPIError(.validationFailed) {
            _ = try await client.registerDevice(idempotencyKey: UUID())
        }
    }

    func testRegisterDeviceMapsCommonStatuses() async {
        let cases: [(Int, MosemoAPIError)] = [
            (404, .unexpectedResponse(statusCode: 404)),
            (405, .unexpectedResponse(statusCode: 405)),
            (418, .unexpectedResponse(statusCode: 418)),
            (500, .serverError(statusCode: 500)),
            (503, .serverError(statusCode: 503)),
        ]

        for (statusCode, expectedError) in cases {
            let client = makeClient(devicesCreate: { _ in
                deviceOutput(statusCode: statusCode)
            })

            await assertAPIError(expectedError) {
                _ = try await client.registerDevice(idempotencyKey: UUID())
            }
        }
    }

    func testRegisterDeviceMapsTransportErrors() async {
        let cases: [(URLError.Code, MosemoAPIError)] = [
            (.timedOut, .timedOut),
            (.notConnectedToInternet, .networkUnavailable),
        ]

        for (code, expectedError) in cases {
            let client = makeClient(devicesCreate: { _ in
                throw URLError(code)
            })

            await assertAPIError(expectedError) {
                _ = try await client.registerDevice(idempotencyKey: UUID())
            }
        }
    }

    func testGeneratedDeviceCreateSendsExactRequest() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "registration-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let recorder = RequestRecorder()
        let responseData = makeDeviceResponse(
            id: "01890F8E-7B5A-7CC0-98C7-8F3E12345678"
        )
        let transport = RecordingClientTransport { request, body, baseURL, operationID in
            await recorder.record(
                request: request,
                hasBody: body != nil,
                baseURL: baseURL,
                operationID: operationID
            )
            return (
                HTTPResponse(
                    status: .created,
                    headerFields: [.contentType: "application/json"]
                ),
                HTTPBody(responseData)
            )
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)
        let repeatedKey = UUID(
            uuidString: "550E8400-E29B-41D4-A716-446655440000"
        )!
        let differentKey = UUID(
            uuidString: "550E8400-E29B-41D4-A716-446655440001"
        )!

        _ = try await client.registerDevice(idempotencyKey: repeatedKey)
        _ = try await client.registerDevice(idempotencyKey: repeatedKey)
        _ = try await client.registerDevice(idempotencyKey: differentKey)

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 3)
        let idempotencyKeyHeader = try XCTUnwrap(
            HTTPField.Name("Idempotency-Key")
        )
        for (request, expectedKey) in zip(
            requests,
            [repeatedKey, repeatedKey, differentKey]
        ) {
            XCTAssertEqual(request.request.method, .post)
            XCTAssertEqual(request.request.path, "/api/v1/devices")
            XCTAssertEqual(
                request.request.headerFields[.authorization],
                "Bearer registration-token"
            )
            XCTAssertEqual(
                request.request.headerFields[idempotencyKeyHeader],
                expectedKey.uuidString
            )
            XCTAssertEqual(request.request.headerFields[.accept], "application/json")
            XCTAssertNil(request.request.headerFields[.contentType])
            XCTAssertFalse(request.hasBody)
            XCTAssertEqual(request.baseURL, baseURL)
            XCTAssertEqual(request.operationID, "devicesCreate")
        }
    }

    func testGeneratedDeviceCreateStopsWithoutToken() async {
        let recorder = RequestRecorder()
        let transport = RecordingClientTransport { request, body, baseURL, operationID in
            await recorder.record(
                request: request,
                hasBody: body != nil,
                baseURL: baseURL,
                operationID: operationID
            )
            return (HTTPResponse(status: .created), nil)
        }
        let client = makeTransportClient(
            tokenStore: MemoryAccessTokenStore(),
            transport: transport
        )

        await assertAPIError(.authenticationRequired) {
            _ = try await client.registerDevice(idempotencyKey: UUID())
        }

        let requests = await recorder.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testGeneratedDeviceCreateDoesNotRetryTransportFailure() async {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "registration-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let recorder = RequestRecorder()
        let transport = RecordingClientTransport { request, body, baseURL, operationID in
            await recorder.record(
                request: request,
                hasBody: body != nil,
                baseURL: baseURL,
                operationID: operationID
            )
            throw URLError(.networkConnectionLost)
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)

        await assertAPIError(.networkUnavailable) {
            _ = try await client.registerDevice(idempotencyKey: UUID())
        }

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testUndocumentedServerResponseMapsStatusCode() async {
        let client = makeClient(getMe: { _ in
            .undocumented(statusCode: 503, .init())
        })

        await assertAPIError(.serverError(statusCode: 503)) {
            _ = try await client.currentAccount()
        }
    }

    func testTransportTimeoutIsMapped() async {
        let client = makeClient(getMe: { _ in
            throw URLError(.timedOut)
        })

        await assertAPIError(.timedOut) {
            _ = try await client.currentAccount()
        }
    }

    func testTransportNetworkFailureIsMapped() async {
        let client = makeClient(getMe: { _ in
            throw URLError(.notConnectedToInternet)
        })

        await assertAPIError(.networkUnavailable) {
            _ = try await client.currentAccount()
        }
    }

    func testCreateActivityUsesDeviceResolvedFromAccountState() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosemo-activity-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let account = Account(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            provider: .kakao,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneID: "Asia/Seoul"
        )
        let deviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let eventID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let store = try SQLiteDeviceRegistrationStateStore(databaseURL: databaseURL)
        try await store.save(
            DeviceRegistrationState(deviceID: deviceID),
            for: account.id
        )
        let metadata = try await ActivityRecordMetadataResolver(stateStore: store).resolve(
            for: account,
            eventID: eventID,
            sequence: 7,
            observedAt: Date(timeIntervalSince1970: 1_800_000_100),
            timezoneID: "Asia/Seoul",
            utcOffsetMinutes: 540
        )
        let client = makeClient(createActivity: { input in
            guard case .json(.activityObservation(let observation)) = input.body else {
                XCTFail("Expected an activity observation")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(observation.deviceId, deviceID.uuidString)
            return .created(.init(body: .json(.init(
                eventId: eventID.uuidString,
                receivedAt: self.now,
                status: .accepted
            ))))
        })

        _ = try await client.createActivity(.observation(.init(
            metadata: metadata,
            context: .opaque
        )))
    }

    func testMissingStoredDeviceStopsBeforeActivityRequest() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosemo-activity-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let account = Account(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            provider: .kakao,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneID: "Asia/Seoul"
        )
        let store = try SQLiteDeviceRegistrationStateStore(databaseURL: databaseURL)
        let resolver = ActivityRecordMetadataResolver(stateStore: store)
        let calls = CallCounter()
        let client = makeClient(createActivity: { _ in
            await calls.increment()
            return .undocumented(statusCode: 500, .init())
        })

        await assertAPIError(.deviceRegistrationRequired) {
            let metadata = try await resolver.resolve(
                for: account,
                eventID: UUID(),
                sequence: 1,
                observedAt: Date(timeIntervalSince1970: 1_800_000_100),
                timezoneID: "Asia/Seoul",
                utcOffsetMinutes: 540
            )
            _ = try await client.createActivity(.observation(.init(
                metadata: metadata,
                context: .opaque
            )))
        }

        let callCount = await calls.value()
        XCTAssertEqual(callCount, 0)
    }

    func testCreateActivityMapsDetailedBrowserObservation() async throws {
        let metadata = makeActivityMetadata()
        let receivedAt = now.addingTimeInterval(5)
        let record = ActivityRecord.observation(.init(
            metadata: metadata,
            context: .detailed(.init(
                app: .init(bundleID: .captured("com.example.app"), name: .absent),
                window: .unavailable(reason: "permission_missing"),
                web: .browser(.init(
                    tabTitle: .captured(.init(
                        value: "A title",
                        truncated: true,
                        originalByteLength: 42
                    )),
                    url: .redacted(reason: "privacy_rule")
                ))
            ))
        ))
        let client = makeClient(createActivity: { input in
            guard case .json(.activityObservation(let observation)) = input.body else {
                XCTFail("Expected an activity observation")
                return .undocumented(statusCode: 500, .init())
            }

            XCTAssertEqual(observation.deviceId, metadata.deviceRegistrationID.uuidString)
            XCTAssertEqual(observation.eventId, metadata.eventID.uuidString)
            XCTAssertEqual(observation.sequence, 7)
            XCTAssertEqual(observation.observedAt, metadata.observedAt)
            XCTAssertEqual(observation.timezoneId, .asiaSeoul)
            XCTAssertEqual(observation.utcOffsetMinutes, 540)
            XCTAssertEqual(observation.recordType, .activityObservation)

            guard case .detailed(let context) = observation.context else {
                XCTFail("Expected detailed context")
                return .undocumented(statusCode: 500, .init())
            }
            guard case .captured(let bundleID) = context.app.bundleId else {
                XCTFail("Expected captured bundle ID")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(bundleID.value, "com.example.app")
            guard case .absent = context.app.name else {
                XCTFail("Expected absent app name")
                return .undocumented(statusCode: 500, .init())
            }
            guard case .unavailable(let window) = context.window else {
                XCTFail("Expected unavailable window")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(window.reason, "permission_missing")
            guard case .browser(let browser) = context.web,
                  case .captured(let title) = browser.tabTitle,
                  case .redacted(let url) = browser.url else {
                XCTFail("Expected captured title and redacted URL")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(title.value, "A title")
            XCTAssertEqual(title.truncated, true)
            XCTAssertEqual(title.originalByteLength, 42)
            XCTAssertEqual(url.reason, "privacy_rule")

            return .created(.init(body: .json(.init(
                eventId: metadata.eventID.uuidString,
                receivedAt: receivedAt,
                status: .accepted
            ))))
        })

        let result = try await client.createActivity(record)

        XCTAssertEqual(result, ActivityCreateResult(
            eventID: metadata.eventID,
            receivedAt: receivedAt
        ))
    }

    func testCreateActivityMapsOpaqueObservation() async throws {
        let metadata = makeActivityMetadata()
        let client = makeClient(createActivity: { input in
            guard case .json(.activityObservation(let observation)) = input.body,
                  case .opaque(let context) = observation.context else {
                XCTFail("Expected opaque activity observation")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(context.kind, .opaque)
            return .created(.init(body: .json(.init(
                eventId: metadata.eventID.uuidString,
                receivedAt: self.now,
                status: .accepted
            ))))
        })

        _ = try await client.createActivity(.observation(.init(
            metadata: metadata,
            context: .opaque
        )))
    }

    func testCreateActivityMapsNonBrowserAndOptionalTextLength() async throws {
        let metadata = makeActivityMetadata()
        let client = makeClient(createActivity: { input in
            guard case .json(.activityObservation(let observation)) = input.body,
                  case .detailed(let context) = observation.context,
                  case .unavailable(let bundleID) = context.app.bundleId,
                  case .captured(let name) = context.app.name,
                  case .captured(let window) = context.window,
                  case .notApplicable = context.web else {
                XCTFail("Expected non-browser detailed context")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(bundleID.reason, "bundle_unavailable")
            XCTAssertEqual(name.value, "Example")
            XCTAssertEqual(window.title.value, "Window")
            XCTAssertNil(window.title.originalByteLength)

            let encoded = try JSONEncoder().encode(observation)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            XCTAssertEqual(object["recordType"] as? String, "activity_observation")
            let contextObject = try XCTUnwrap(object["context"] as? [String: Any])
            let windowObject = try XCTUnwrap(contextObject["window"] as? [String: Any])
            let titleObject = try XCTUnwrap(windowObject["title"] as? [String: Any])
            XCTAssertNil(titleObject["originalByteLength"])
            XCTAssertEqual(contextObject["kind"] as? String, "detailed")
            let webObject = try XCTUnwrap(contextObject["web"] as? [String: Any])
            XCTAssertEqual(webObject["kind"] as? String, "not_applicable")

            return .created(.init(body: .json(.init(
                eventId: metadata.eventID.uuidString,
                receivedAt: self.now,
                status: .accepted
            ))))
        })

        _ = try await client.createActivity(.observation(.init(
            metadata: metadata,
            context: .detailed(.init(
                app: .init(
                    bundleID: .unavailable(reason: "bundle_unavailable"),
                    name: .captured("Example")
                ),
                window: .captured(title: .init(value: "Window")),
                web: .notApplicable
            ))
        )))
    }

    func testCreateActivityMapsRemainingDetailedValueStates() async throws {
        let metadata = makeActivityMetadata()
        let redactedTitleClient = makeClient(createActivity: { input in
            guard case .json(.activityObservation(let observation)) = input.body,
                  case .detailed(let context) = observation.context,
                  case .absent = context.app.bundleId,
                  case .unavailable(let name) = context.app.name,
                  case .absent = context.window,
                  case .browser(let browser) = context.web,
                  case .redacted(let title) = browser.tabTitle,
                  case .captured(let url) = browser.url else {
                XCTFail("Expected remaining detailed value states")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(name.reason, "name_unavailable")
            XCTAssertEqual(title.reason, "title_private")
            XCTAssertEqual(url.value, "https://example.com")
            return .created(.init(body: .json(.init(
                eventId: metadata.eventID.uuidString,
                receivedAt: self.now,
                status: .accepted
            ))))
        })
        let unavailableTitleAbsentURLClient = makeClient(createActivity: { input in
            guard case .json(.activityObservation(let observation)) = input.body,
                  case .detailed(let context) = observation.context,
                  case .browser(let browser) = context.web,
                  case .unavailable(let title) = browser.tabTitle,
                  case .absent = browser.url else {
                XCTFail("Expected unavailable tab title and absent URL")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(title.reason, "automation_denied")

            let encoded = try JSONEncoder().encode(observation)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            XCTAssertEqual(object["recordType"] as? String, "activity_observation")
            let contextObject = try XCTUnwrap(object["context"] as? [String: Any])
            XCTAssertEqual(contextObject["kind"] as? String, "detailed")
            let webObject = try XCTUnwrap(contextObject["web"] as? [String: Any])
            XCTAssertEqual(webObject["kind"] as? String, "browser")
            let titleObject = try XCTUnwrap(webObject["tabTitle"] as? [String: Any])
            XCTAssertEqual(titleObject["status"] as? String, "unavailable")
            XCTAssertEqual(titleObject["reason"] as? String, "automation_denied")
            let urlObject = try XCTUnwrap(webObject["url"] as? [String: Any])
            XCTAssertEqual(urlObject["status"] as? String, "absent")
            return .created(.init(body: .json(.init(
                eventId: metadata.eventID.uuidString,
                receivedAt: self.now,
                status: .accepted
            ))))
        })

        _ = try await redactedTitleClient.createActivity(.observation(.init(
            metadata: metadata,
            context: .detailed(.init(
                app: .init(
                    bundleID: .absent,
                    name: .unavailable(reason: "name_unavailable")
                ),
                window: .absent,
                web: .browser(.init(
                    tabTitle: .redacted(reason: "title_private"),
                    url: .captured("https://example.com")
                ))
            ))
        )))
        _ = try await unavailableTitleAbsentURLClient.createActivity(.observation(.init(
            metadata: metadata,
            context: .detailed(.init(
                app: .init(bundleID: .absent, name: .absent),
                window: .absent,
                web: .browser(.init(
                    tabTitle: .unavailable(reason: "automation_denied"),
                    url: .absent
                ))
            ))
        )))
    }

    func testCreateActivityMapsCollectionStateChange() async throws {
        let metadata = makeActivityMetadata()
        let client = makeClient(createActivity: { input in
            guard case .json(.collectionStateChanged(let change)) = input.body else {
                XCTFail("Expected collection state change")
                return .undocumented(statusCode: 500, .init())
            }
            XCTAssertEqual(change.deviceId, metadata.deviceRegistrationID.uuidString)
            XCTAssertEqual(change.eventId, metadata.eventID.uuidString)
            XCTAssertEqual(change.recordType, .collectionStateChanged)
            XCTAssertEqual(change.state, .suspended)
            XCTAssertEqual(change.reason, "system_sleep")
            XCTAssertEqual(change.sequence, metadata.sequence)
            XCTAssertEqual(change.observedAt, metadata.observedAt)
            XCTAssertEqual(change.timezoneId, .asiaSeoul)
            XCTAssertEqual(change.utcOffsetMinutes, metadata.utcOffsetMinutes)
            return .created(.init(body: .json(.init(
                eventId: metadata.eventID.uuidString,
                receivedAt: self.now,
                status: .accepted
            ))))
        })

        _ = try await client.createActivity(.collectionStateChanged(.init(
            metadata: metadata,
            state: .suspended,
            reason: "system_sleep"
        )))
    }

    func testCreateActivityReturnsSameServerResultForExplicitRetry() async throws {
        let metadata = makeActivityMetadata()
        let calls = CallCounter()
        let receivedAt = now.addingTimeInterval(10)
        let client = makeClient(createActivity: { _ in
            await calls.increment()
            return .created(.init(body: .json(.init(
                eventId: metadata.eventID.uuidString,
                receivedAt: receivedAt,
                status: .accepted
            ))))
        })
        let record = ActivityRecord.observation(.init(
            metadata: metadata,
            context: .opaque
        ))

        let first = try await client.createActivity(record)
        let retry = try await client.createActivity(record)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.receivedAt, receivedAt)
        let callCount = await calls.value()
        XCTAssertEqual(callCount, 2)
    }

    func testCreateActivityRejectsInvalidOrMismatchedResponseEventID() async {
        let metadata = makeActivityMetadata()
        let invalidClient = makeClient(createActivity: { _ in
            .created(.init(body: .json(.init(
                eventId: "not-a-uuid",
                receivedAt: self.now,
                status: .accepted
            ))))
        })
        let mismatchedClient = makeClient(createActivity: { _ in
            .created(.init(body: .json(.init(
                eventId: UUID().uuidString,
                receivedAt: self.now,
                status: .accepted
            ))))
        })
        let record = ActivityRecord.observation(.init(
            metadata: metadata,
            context: .opaque
        ))

        await assertAPIError(.unexpectedResponse(statusCode: 201)) {
            _ = try await invalidClient.createActivity(record)
        }
        await assertAPIError(.unexpectedResponse(statusCode: 201)) {
            _ = try await mismatchedClient.createActivity(record)
        }
    }

    func testCreateActivityClearsTokenOnUnauthorized() async throws {
        let metadata = makeActivityMetadata()
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "stored-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let client = makeClient(
            tokenStore: tokenStore,
            createActivity: { _ in
                .unauthorized(.init(body: .json(makeErrorResponse(
                    code: 401,
                    status: "AUTH_INVALID_ACCESS_TOKEN",
                    message: "unauthorized"
                ))))
            }
        )

        await assertAPIError(.authenticationRequired) {
            _ = try await client.createActivity(.observation(.init(
                metadata: metadata,
                context: .opaque
            )))
        }
        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testCreateActivityPreservesAuthenticationRequiredWhenTokenDeleteFails() async {
        let tokenStore = FailingDeleteTokenStore()
        let client = makeClient(
            tokenStore: tokenStore,
            createActivity: { _ in
                .unauthorized(.init(body: .json(makeErrorResponse(
                    code: 401,
                    status: "AUTH_INVALID_ACCESS_TOKEN",
                    message: "unauthorized"
                ))))
            }
        )

        await assertAPIError(.authenticationRequired) {
            _ = try await client.createActivity(.observation(.init(
                metadata: self.makeActivityMetadata(),
                context: .opaque
            )))
        }
        let deleteCallCount = await tokenStore.deleteCallCount()
        XCTAssertEqual(deleteCallCount, 1)
    }

    func testCreateActivityMapsDeviceNotFound() async {
        let metadata = makeActivityMetadata()
        let client = makeClient(createActivity: { _ in
            .notFound(.init(body: .json(makeErrorResponse(
                code: 404,
                status: "ACTIVITY_DEVICE_NOT_FOUND",
                message: "device not found"
            ))))
        })

        await assertAPIError(.activityDeviceNotFound) {
            _ = try await client.createActivity(.observation(.init(
                metadata: metadata,
                context: .opaque
            )))
        }
    }

    func testCreateActivityMapsBothConflictReasonsWithoutRetrying() async {
        let metadata = makeActivityMetadata()
        let cases: [(String, MosemoAPIError)] = [
            ("ACTIVITY_EVENT_ID_CONFLICT", .activityEventIDConflict),
            ("ACTIVITY_SEQUENCE_CONFLICT", .activitySequenceConflict),
        ]

        for (status, expectedError) in cases {
            let calls = CallCounter()
            let client = makeClient(createActivity: { _ in
                await calls.increment()
                return .conflict(.init(body: .json(makeErrorResponse(
                    code: 409,
                    status: status,
                    message: "conflict"
                ))))
            })

            await assertAPIError(expectedError) {
                _ = try await client.createActivity(.observation(.init(
                    metadata: metadata,
                    context: .opaque
                )))
            }
            let callCount = await calls.value()
            XCTAssertEqual(callCount, 1)
        }
    }

    func testCreateActivityMapsValidationServerAndUndocumentedErrors() async {
        let metadata = makeActivityMetadata()
        let record = ActivityRecord.observation(.init(
            metadata: metadata,
            context: .opaque
        ))
        let validationClient = makeClient(createActivity: { _ in
            .unprocessableContent(.init(body: .json(makeErrorResponse(
                code: 422,
                status: "INVALID_ARGUMENT",
                message: "validation failed"
            ))))
        })
        let serverClient = makeClient(createActivity: { _ in
            .internalServerError(.init(body: .json(makeErrorResponse(
                code: 500,
                status: "INTERNAL_SERVER_ERROR",
                message: "server error"
            ))))
        })
        let undocumentedClient = makeClient(createActivity: { _ in
            .undocumented(statusCode: 503, .init())
        })
        let methodClient = makeClient(createActivity: { _ in
            .methodNotAllowed(.init(body: .json(makeErrorResponse(
                code: 405,
                status: "REQUEST_METHOD_NOT_ALLOWED",
                message: "method not allowed"
            ))))
        })

        await assertAPIError(.validationFailed) {
            _ = try await validationClient.createActivity(record)
        }
        await assertAPIError(.retryableServerError(statusCode: 500, retryAfter: nil)) {
            _ = try await serverClient.createActivity(record)
        }
        await assertAPIError(.retryableServerError(statusCode: 503, retryAfter: nil)) {
            _ = try await undocumentedClient.createActivity(record)
        }
        await assertAPIError(.unexpectedResponse(statusCode: 405)) {
            _ = try await methodClient.createActivity(record)
        }
    }

    func testCreateActivityPreservesRetryAfterForUndocumentedRateLimit() async {
        let metadata = makeActivityMetadata()
        let record = ActivityRecord.observation(.init(metadata: metadata, context: .opaque))
        let client = makeClient(createActivity: { _ in
            .undocumented(statusCode: 429, .init(headerFields: [HTTPField.Name("Retry-After")!: "4"]))
        })

        await assertAPIError(.retryableServerError(statusCode: 429, retryAfter: 4)) {
            _ = try await client.createActivity(record)
        }
    }

    func testCreateActivityPreservesRetryAfterForServiceUnavailable() async {
        let metadata = makeActivityMetadata()
        let record = ActivityRecord.observation(.init(metadata: metadata, context: .opaque))
        let client = makeClient(createActivity: { _ in
            .serviceUnavailable(.init(
                headers: .init(retryAfter: ._1),
                body: .json(makeErrorResponse(code: 503, status: "BUSY", message: "retry later"))
            ))
        })

        await assertAPIError(.retryableServerError(statusCode: 503, retryAfter: 1)) {
            _ = try await client.createActivity(record)
        }
    }

    func testCreateActivityMapsTransportErrorsWithoutRetrying() async {
        let metadata = makeActivityMetadata()
        let record = ActivityRecord.observation(.init(
            metadata: metadata,
            context: .opaque
        ))
        let timeoutCalls = CallCounter()
        let timeoutClient = makeClient(createActivity: { _ in
            await timeoutCalls.increment()
            throw URLError(.timedOut)
        })
        let networkCalls = CallCounter()
        let networkClient = makeClient(createActivity: { _ in
            await networkCalls.increment()
            throw URLError(.notConnectedToInternet)
        })

        await assertAPIError(.timedOut) {
            _ = try await timeoutClient.createActivity(record)
        }
        await assertAPIError(.networkUnavailable) {
            _ = try await networkClient.createActivity(record)
        }
        let timeoutCallCount = await timeoutCalls.value()
        let networkCallCount = await networkCalls.value()
        XCTAssertEqual(timeoutCallCount, 1)
        XCTAssertEqual(networkCallCount, 1)
    }

    func testAuthenticationMiddlewareAddsBearerHeader() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "header-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let recorder = HeaderRecorder()
        let middleware = BearerAuthenticationMiddleware(
            tokenStore: tokenStore,
            now: { self.now }
        )

        _ = try await middleware.intercept(
            HTTPRequest(method: .get, scheme: "https", authority: "api.test", path: "/me"),
            body: nil,
            baseURL: baseURL,
            operationID: "get-me"
        ) { request, _, _ in
            await recorder.record(request.headerFields[.authorization])
            return (HTTPResponse(status: .ok), nil)
        }

        let authorization = await recorder.authorization()
        XCTAssertEqual(authorization, "Bearer header-token")
    }

    func testAuthenticationMiddlewareDeletesExpiredToken() async {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "expired-token",
            expiresAt: now
        ))
        let middleware = BearerAuthenticationMiddleware(
            tokenStore: tokenStore,
            now: { self.now }
        )

        await assertAPIError(.authenticationRequired) {
            _ = try await middleware.intercept(
                HTTPRequest(method: .get, scheme: "https", authority: "api.test", path: "/me"),
                body: nil,
                baseURL: self.baseURL,
                operationID: "get-me"
            ) { _, _, _ in
                XCTFail("Expired credentials must stop before transport")
                return (HTTPResponse(status: .ok), nil)
            }
        }
        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testSignOutDeletesToken() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "stored-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let client = makeClient(tokenStore: tokenStore)

        try await client.signOut()

        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testKeychainStoreRoundTrip() async throws {
        let store = KeychainAccessTokenStore(
            service: "io.mosemo.app.tests.\(UUID().uuidString)",
            account: "access-token"
        )
        let token = StoredAccessToken(
            value: "keychain-test-token",
            expiresAt: now.addingTimeInterval(60)
        )

        try await store.save(token)
        let loadedToken = try await store.load()
        XCTAssertEqual(loadedToken, token)
        try await store.delete()
        let deletedToken = try await store.load()
        XCTAssertNil(deletedToken)
    }

    func testPKCEUsesRFC7636Example() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        XCTAssertEqual(
            try PKCE.codeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testGeneratedPKCEVerifierMeetsContract() throws {
        let verifier = try PKCE.makeCodeVerifier()

        XCTAssertEqual(verifier.count, 43)
        XCTAssertEqual(try PKCE.codeChallenge(for: verifier).count, 43)
    }

    func testKakaoLoginURLContainsOnlyPKCEParameters() throws {
        let challenge = String(repeating: "a", count: 43)
        let client = makeClient()

        let url = try client.makeKakaoLoginURL(codeChallenge: challenge)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.path, "/api/v1/auth/kakao/login")
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
    }

    func testAuthenticationCallbackParsesSingleCode() throws {
        let url = URL(string: "io.mosemo.app:/auth/callback?code=one-time-code")!

        XCTAssertEqual(
            try AuthenticationCallback.authorizationCode(from: url),
            "one-time-code"
        )
    }

    func testAuthenticationCallbackMapsAccessDenied() {
        let url = URL(string: "io.mosemo.app:/auth/callback?error=access_denied")!

        XCTAssertThrowsError(try AuthenticationCallback.authorizationCode(from: url)) {
            XCTAssertEqual($0 as? AuthenticationCallbackError, .cancelled)
        }
    }

    func testAuthenticationCallbackMapsProviderFailure() {
        let url = URL(string: "io.mosemo.app:/auth/callback?error=server_error")!

        XCTAssertThrowsError(try AuthenticationCallback.authorizationCode(from: url)) {
            XCTAssertEqual($0 as? AuthenticationCallbackError, .authenticationFailed)
        }
    }

    func testAuthenticationCallbackRejectsWrongPathAndDuplicateCode() {
        let wrongPath = URL(string: "io.mosemo.app:/wrong?code=code")!
        let duplicate = URL(string: "io.mosemo.app:/auth/callback?code=one&code=two")!

        for url in [wrongPath, duplicate] {
            XCTAssertThrowsError(try AuthenticationCallback.authorizationCode(from: url)) {
                XCTAssertEqual($0 as? AuthenticationCallbackError, .invalidCallback)
            }
        }
    }

    func testListLabelsMapsActiveAndArchivedEntriesFromAuthenticatedResponse() async throws {
        let activeLabelID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let archivedLabelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let recorder = RequestRecorder()
        let body = Data(#"""
        [
          {"labelId":"11111111-1111-1111-1111-111111111111","displayName":"코딩","createdAt":"2026-09-20T00:00:00Z","updatedAt":"2026-09-25T00:00:00Z","archivedAt":null},
          {"labelId":"22222222-2222-2222-2222-222222222222","displayName":"옛 라벨","createdAt":"2026-09-20T00:00:00Z","updatedAt":"2026-09-26T00:00:00Z","archivedAt":"2026-09-27T00:00:00Z"}
        ]
        """#.utf8)
        let transport = RecordingClientTransport { request, requestBody, baseURL, operationID in
            await recorder.record(request: request, hasBody: requestBody != nil,
                                  baseURL: baseURL, operationID: operationID)
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        let client = makeTransportClient(
            tokenStore: MemoryAccessTokenStore(token: .init(
                value: "review-token",
                expiresAt: now.addingTimeInterval(60)
            )),
            transport: transport
        )

        let labels = try await client.listLabels()

        XCTAssertEqual(labels, [
            LabelCatalogEntry(id: activeLabelID, displayName: "코딩", archivedAt: nil),
            LabelCatalogEntry(
                id: archivedLabelID,
                displayName: "옛 라벨",
                archivedAt: Date(timeIntervalSince1970: 1_790_467_200)
            ),
        ])
        let requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.request.path), ["/api/v1/labels"])
        XCTAssertEqual(requests.map(\.operationID), ["labelsList"])
        XCTAssertEqual(requests[0].request.headerFields[.authorization], "Bearer review-token")
    }

    func testListLabelsClearsTokenOnUnauthorizedResponse() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "expired-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let transport = RecordingClientTransport { _, _, _, _ in
            let error = Data(#"{"error":{"code":401,"details":[],"message":"Invalid or expired access token","status":"AUTH_INVALID_ACCESS_TOKEN"}}"#.utf8)
            return (HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]), HTTPBody(error))
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)

        await assertAPIError(.authenticationRequired) {
            _ = try await client.listLabels()
        }

        let storedToken = await tokenStore.currentToken()
        XCTAssertNil(storedToken)
    }

    func testLabelTimelineUsesSelectedDateAndMapsPendingSegment() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(
            value: "review-token",
            expiresAt: now.addingTimeInterval(60)
        ))
        let recorder = RequestRecorder()
        let body = Data(#"""
        [{"itemType":"activity_group","groupVersion":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:05:00Z","state":"pending","selection":null,"segments":[{"segmentId":"11111111-1111-1111-1111-111111111111","segmentVersion":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:05:00Z","lastObservedAt":"2026-09-26T00:04:00Z","context":{"kind":"detailed","app":{"bundleId":{"status":"absent"},"name":{"status":"captured","value":"Xcode"}},"window":{"status":"captured","title":{"status":"captured","value":"Editor.swift"}},"web":{"kind":"not_applicable"}}}]}]
        """#.utf8)
        let transport = RecordingClientTransport { request, requestBody, baseURL, operationID in
            await recorder.record(request: request, hasBody: requestBody != nil,
                                  baseURL: baseURL, operationID: operationID)
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        let client = makeTransportClient(tokenStore: tokenStore, transport: transport)

        let segments = try await client.pendingLabelSegments(day: TimelineDate(year: 2026, month: 9, day: 26))

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(segments[0].version, String(repeating: "b", count: 64))
        XCTAssertEqual(segments[0].sourceGroupVersion, String(repeating: "a", count: 64))
        XCTAssertEqual(segments[0].appName, "Xcode")
        XCTAssertEqual(segments[0].title, "Editor.swift")
        let requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.request.path), ["/api/v1/activities/label-timeline?date=2026-09-26"])
        XCTAssertEqual(requests.map(\.operationID), ["activitiesGetLabelTimeline"])
        XCTAssertEqual(requests[0].request.headerFields[.authorization], "Bearer review-token")
    }

    func testReviewPreservesWebContextWithoutWindowFallback() async throws {
        let tokenStore = MemoryAccessTokenStore(token: .init(value: "review-token", expiresAt: now.addingTimeInterval(60)))
        let webValues = [
            #"{"kind":"browser","tabTitle":{"status":"captured","value":"Tab title"},"url":{"status":"captured","value":"https://Example.com/path?q=a%20b#anchor"}}"#,
            #"{"kind":"browser","tabTitle":{"status":"unavailable","reason":"not_supported"},"url":{"status":"captured","value":"https://example.com/only-url"}}"#,
            #"{"kind":"browser","tabTitle":{"status":"captured","value":"Only title"},"url":{"status":"unavailable","reason":"not_supported"}}"#,
            #"{"kind":"not_applicable"}"#,
        ]
        let segments = webValues.enumerated().map { index, web in
            """
            {"segmentId":"00000000-0000-0000-0000-00000000000\(index + 1)","segmentVersion":"\(String(repeating: "b", count: 64))","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:05:00Z","lastObservedAt":"2026-09-26T00:04:00Z","context":{"kind":"detailed","app":{"bundleId":{"status":"absent"},"name":{"status":"captured","value":"Chrome"}},"window":{"status":"captured","title":{"status":"captured","value":"Window title"}},"web":\(web)}}
            """
        }.joined(separator: ",")
        let body = Data("""
        [{"itemType":"activity_group","groupVersion":"\(String(repeating: "a", count: 64))","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:05:00Z","state":"pending","selection":null,"segments":[\(segments)]}]
        """.utf8)
        let recorder = RequestRecorder()
        let transport = RecordingClientTransport { request, requestBody, baseURL, operationID in
            await recorder.record(request: request, hasBody: requestBody != nil, baseURL: baseURL, operationID: operationID)
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        let result = try await makeTransportClient(tokenStore: tokenStore, transport: transport)
            .pendingLabelSegments(day: TimelineDate(year: 2026, month: 9, day: 26))
        XCTAssertEqual(result.map(\.context), [
            .web(title: "Tab title", url: "https://Example.com/path?q=a%20b#anchor"),
            .web(title: nil, url: "https://example.com/only-url"),
            .web(title: "Only title", url: nil),
            .app(title: "Window title"),
        ])
        let requests = await recorder.requests()
        XCTAssertEqual(requests.first?.request.headerFields[.authorization], "Bearer review-token")
    }

    func testLabelStateMapsReadyAndUnclassifiedProposals() async throws {
        let segmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let labelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let version = String(repeating: "a", count: 64)
        let responses: [(String, RemoteLabelProposal)] = [
            (#"{"status":"ready","selection":{"kind":"label","labelId":"22222222-2222-2222-2222-222222222222"},"suggestedAt":"2026-09-27T00:00:00Z"}"#, .readyLabel(labelID)),
            (#"{"status":"ready","selection":{"kind":"unclassified"},"suggestedAt":"2026-09-27T00:00:00Z"}"#, .readyUnclassified),
            (#"{"status":"waiting"}"#, .waiting),
            (#"{"status":"processing"}"#, .processing),
            (#"{"status":"failed"}"#, .failed),
        ]
        for (proposalJSON, expected) in responses {
            let responseJSON = #"{"segmentId":"11111111-1111-1111-1111-111111111111","segmentVersion":""#
                + version + #"","state":"pending","proposal":"# + proposalJSON + "}"
            let transport = RecordingClientTransport { _, _, _, _ in
                (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
                 HTTPBody(Data(responseJSON.utf8)))
            }
            let client = makeTransportClient(
                tokenStore: MemoryAccessTokenStore(token: .init(value: "review-token", expiresAt: now.addingTimeInterval(60))),
                transport: transport
            )

            let state = try await client.labelState(segmentID: segmentID)

            XCTAssertEqual(state, .pending(id: segmentID, version: version, proposal: expected))
        }
    }

    func testLabelStateMapsCurrentConfirmedSelectionForConflictReview() async throws {
        let segmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let labelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let version = String(repeating: "a", count: 64)
        let body = Data(#"{"segmentId":"11111111-1111-1111-1111-111111111111","segmentVersion":"\#(version)","state":"confirmed","selection":{"kind":"label","labelId":"22222222-2222-2222-2222-222222222222"},"proposal":null,"confirmedAt":"2026-09-28T00:00:00Z","updatedAt":"2026-09-28T00:00:00Z"}"#.utf8)
        let transport = RecordingClientTransport { _, _, _, _ in
            (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        let client = makeTransportClient(
            tokenStore: MemoryAccessTokenStore(token: .init(value: "review-token", expiresAt: now.addingTimeInterval(60))),
            transport: transport
        )

        let state = try await client.labelState(segmentID: segmentID)

        XCTAssertEqual(state, .confirmed(id: segmentID, version: version, selection: .label(labelID)))
    }

    func testLabelTimelineIgnoresConfirmedOpenOpaqueAndCaptureGapItems() async throws {
        let body = Data(#"""
        [
          {"itemType":"activity_group","groupVersion":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:05:00Z","state":"confirmed","selection":{"kind":"label","labelId":"22222222-2222-2222-2222-222222222222","displayName":"코딩"},"segments":[{"segmentId":"11111111-1111-1111-1111-111111111111","segmentVersion":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","startedAt":"2026-09-26T00:00:00Z","endedAt":"2026-09-26T00:05:00Z","lastObservedAt":"2026-09-26T00:04:00Z","context":{"kind":"detailed","app":{"bundleId":{"status":"absent"},"name":{"status":"captured","value":"Xcode"}},"window":{"status":"absent"},"web":{"kind":"not_applicable"}}}]},
          {"itemType":"in_progress_activity","segmentId":"33333333-3333-3333-3333-333333333333","startedAt":"2026-09-26T00:05:00Z","endedAt":null,"lastObservedAt":"2026-09-26T00:06:00Z","context":{"kind":"detailed","app":{"bundleId":{"status":"absent"},"name":{"status":"captured","value":"Xcode"}},"window":{"status":"absent"},"web":{"kind":"not_applicable"}}},
          {"itemType":"opaque_activity","segmentId":"44444444-4444-4444-4444-444444444444","startedAt":"2026-09-26T00:06:00Z","endedAt":null,"lastObservedAt":"2026-09-26T00:07:00Z","context":{"kind":"opaque"}},
          {"itemType":"capture_gap","segmentId":"55555555-5555-5555-5555-555555555555","startedAt":"2026-09-26T00:07:00Z","endedAt":null,"reason":"paused"}
        ]
        """#.utf8)
        let transport = RecordingClientTransport { _, _, _, _ in
            (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        let client = makeTransportClient(
            tokenStore: MemoryAccessTokenStore(token: .init(value: "review-token", expiresAt: now.addingTimeInterval(60))),
            transport: transport
        )

        let segments = try await client.pendingLabelSegments(day: TimelineDate(year: 2026, month: 9, day: 26))

        XCTAssertTrue(segments.isEmpty)
    }

    func testBatchConfirmationSendsPerSegmentChoicesInOneAuthenticatedRequest() async throws {
        let segmentA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let segmentB = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let label = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let firstVersion = String(repeating: "b", count: 64)
        let secondVersion = String(repeating: "c", count: 64)
        let recorder = JSONBodyRecorder()
        let response = Data(#"{"items":[{"segmentId":"11111111-1111-1111-1111-111111111111","segmentVersion":"\#(firstVersion)","state":"confirmed","selection":{"kind":"label","labelId":"22222222-2222-2222-2222-222222222222"},"proposal":null,"confirmedAt":"2026-09-28T00:00:00Z","updatedAt":"2026-09-28T00:00:00Z"},{"segmentId":"33333333-3333-3333-3333-333333333333","segmentVersion":"\#(secondVersion)","state":"confirmed","selection":{"kind":"unclassified"},"proposal":null,"confirmedAt":"2026-09-28T00:00:00Z","updatedAt":"2026-09-28T00:00:00Z"}]}"#.utf8)
        let transport = RecordingClientTransport { request, body, _, operationID in
            var data = Data()
            if let body {
                for try await chunk in body { data.append(contentsOf: chunk) }
            }
            await recorder.record(request: request, operationID: operationID, body: data)
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
        }
        let client = makeTransportClient(
            tokenStore: MemoryAccessTokenStore(token: .init(value: "review-token", expiresAt: now.addingTimeInterval(60))),
            transport: transport
        )

        try await client.confirmSegmentLabels([
            .init(segmentID: segmentA, segmentVersion: firstVersion, selection: .label(label)),
            .init(segmentID: segmentB, segmentVersion: secondVersion, selection: .unclassified),
        ])

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].request.path, "/api/v1/activities/label-confirmations")
        XCTAssertEqual(requests[0].operationID, "activitiesConfirmSegmentLabels")
        XCTAssertEqual(requests[0].request.headerFields[.authorization], "Bearer review-token")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0["segmentId"] as? String }, [segmentA, segmentB].map { $0.uuidString.lowercased() })
        XCTAssertEqual(items.map { ($0["selection"] as? [String: Any])?["kind"] as? String }, ["label", "unclassified"])
        XCTAssertEqual((items[0]["selection"] as? [String: Any])?["labelId"] as? String, label.uuidString.lowercased())
    }

    func testBatchConfirmationMapsPriorSelectionConflictAndFailedItem() async throws {
        let body = Data(#"{"error":{"code":409,"status":"ACTIVITY_LABEL_CONFIRMATION_CONFLICT","message":"conflict","details":[{"loc":["body","items",1,"selection"],"msg":"conflict","type":"activity_label_confirmation_conflict"}]}}"#.utf8)
        let transport = RecordingClientTransport { _, _, _, _ in
            (HTTPResponse(status: .conflict, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        let client = makeTransportClient(
            tokenStore: MemoryAccessTokenStore(token: .init(value: "review-token", expiresAt: now.addingTimeInterval(60))),
            transport: transport
        )

        do {
            try await client.confirmSegmentLabels([
                .init(segmentID: UUID(), segmentVersion: String(repeating: "a", count: 64), selection: .unclassified)
            ])
            XCTFail("Expected conflict")
        } catch let error as LabelConfirmationRejection {
            XCTAssertEqual(error.reason, .priorConfirmationConflict)
            XCTAssertEqual(error.failedIndex, 1)
        }
    }

    func testBatchConfirmationPreservesRetryAfterForTimelineContention() async throws {
        let body = Data(#"{"error":{"code":503,"status":"ACTIVITY_TIMELINE_BUSY","message":"busy","details":[]}}"#.utf8)
        let transport = RecordingClientTransport { _, _, _, _ in
            let fields: HTTPFields = [
                .contentType: "application/json",
                HTTPField.Name("Retry-After")!: "1",
            ]
            return (HTTPResponse(status: .serviceUnavailable, headerFields: fields), HTTPBody(body))
        }
        let client = makeTransportClient(
            tokenStore: MemoryAccessTokenStore(token: .init(value: "review-token", expiresAt: now.addingTimeInterval(60))),
            transport: transport
        )

        do {
            try await client.confirmSegmentLabels([
                .init(segmentID: UUID(), segmentVersion: String(repeating: "a", count: 64), selection: .unclassified)
            ])
            XCTFail("Expected contention")
        } catch let error as LabelConfirmationRejection {
            XCTAssertEqual(error.reason, .timelineBusy)
            XCTAssertEqual(error.retryAfter, 1)
        }
    }

    private func makeClient(
        tokenStore: any AccessTokenStoring = MemoryAccessTokenStore(),
        exchange: @escaping MockGeneratedAPI.Exchange = { _ in
            .undocumented(statusCode: 500, .init())
        },
        getMe: @escaping MockGeneratedAPI.GetMe = { _ in
            .undocumented(statusCode: 500, .init())
        },
        devicesCreate: @escaping MockGeneratedAPI.DevicesCreate = { _ in
            .undocumented(statusCode: 500, .init())
        },
        createActivity: @escaping MockGeneratedAPI.CreateActivity = { _ in
            .undocumented(statusCode: 500, .init())
        }
    ) -> LiveMosemoAPIClient {
        LiveMosemoAPIClient(
            baseURL: baseURL,
            anonymousClient: MockGeneratedAPI(
                exchange: exchange,
                getMe: getMe,
                createDevice: devicesCreate,
                createActivity: createActivity
            ),
            authenticatedClient: MockGeneratedAPI(
                exchange: exchange,
                getMe: getMe,
                createDevice: devicesCreate,
                createActivity: createActivity
            ),
            tokenStore: tokenStore,
            now: { self.now }
        )
    }

    private func makeTransportClient(
        tokenStore: MemoryAccessTokenStore,
        transport: any ClientTransport
    ) -> LiveMosemoAPIClient {
        LiveMosemoAPIClient(
            baseURL: baseURL,
            anonymousClient: MockGeneratedAPI(
                exchange: { _ in .undocumented(statusCode: 500, .init()) },
                getMe: { _ in .undocumented(statusCode: 500, .init()) },
                createDevice: { _ in .undocumented(statusCode: 500, .init()) },
                createActivity: { _ in .undocumented(statusCode: 500, .init()) }
            ),
            authenticatedClient: Client(
                serverURL: baseURL,
                configuration: .init(dateTranscoder: MosemoDateTranscoder()),
                transport: transport,
                middlewares: [BearerAuthenticationMiddleware(
                    tokenStore: tokenStore,
                    now: { self.now }
                )]
            ),
            tokenStore: tokenStore,
            now: { self.now }
        )
    }

    private func makeActivityMetadata() -> ActivityRecordMetadata {
        ActivityRecordMetadata(
            deviceRegistrationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            eventID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sequence: 7,
            observedAt: Date(timeIntervalSince1970: 1_800_000_100),
            timezoneID: "Asia/Seoul",
            utcOffsetMinutes: 540
        )
    }

    private func assertAPIError<T>(
        _ expected: MosemoAPIError,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? MosemoAPIError, expected)
        }
    }
}

private func makeErrorResponse(
    code: Int,
    status: String,
    message: String
) -> Components.Schemas.ErrorResponse {
    .init(error: .init(
        code: code,
        details: [],
        message: message,
        status: status
    ))
}

private func makeDeviceResponse(id: String) -> Data {
    Data(#"{"deviceId":"\#(id)"}"#.utf8)
}

private func deviceOutput(statusCode: Int) -> Operations.DevicesCreate.Output {
    let error = makeErrorResponse(
        code: statusCode,
        status: "TEST_ERROR",
        message: "test error"
    )
    switch statusCode {
    case 404:
        return .notFound(.init(body: .json(error)))
    case 405:
        return .methodNotAllowed(.init(body: .json(error)))
    case 500:
        return .internalServerError(.init(body: .json(error)))
    default:
        return .undocumented(statusCode: statusCode, .init())
    }
}

private struct MockGeneratedAPI: APIProtocol {
    var createFocus: @Sendable (Operations.FocusSessionsCreate.Input) async throws -> Operations.FocusSessionsCreate.Output = { _ in .undocumented(statusCode: 500, .init()) }
    var completeFocus: @Sendable (Operations.FocusSessionsComplete.Input) async throws -> Operations.FocusSessionsComplete.Output = { _ in .undocumented(statusCode: 500, .init()) }
    var listFocus: @Sendable (Operations.FocusSessionsList.Input) async throws -> Operations.FocusSessionsList.Output = { _ in .undocumented(statusCode: 500, .init()) }
    func focusSessionsCreate(_ input: Operations.FocusSessionsCreate.Input) async throws -> Operations.FocusSessionsCreate.Output { try await createFocus(input) }
    func focusSessionsComplete(_ input: Operations.FocusSessionsComplete.Input) async throws -> Operations.FocusSessionsComplete.Output { try await completeFocus(input) }
    func focusSessionsList(_ input: Operations.FocusSessionsList.Input) async throws -> Operations.FocusSessionsList.Output { try await listFocus(input) }

    typealias Exchange = @Sendable (
        Operations.AuthExchangeToken.Input
    ) async throws -> Operations.AuthExchangeToken.Output
    typealias GetMe = @Sendable (
        Operations.AccountsGetMe.Input
    ) async throws -> Operations.AccountsGetMe.Output
    typealias DevicesCreate = @Sendable (
        Operations.DevicesCreate.Input
    ) async throws -> Operations.DevicesCreate.Output
    typealias CreateActivity = @Sendable (
        Operations.ActivitiesCreate.Input
    ) async throws -> Operations.ActivitiesCreate.Output
    typealias GetTimeline = @Sendable (
        Operations.ActivitiesGetTimeline.Input
    ) async throws -> Operations.ActivitiesGetTimeline.Output

    let exchange: Exchange
    let getMe: GetMe
    let createDevice: DevicesCreate
    let createActivity: CreateActivity
    let getTimeline: GetTimeline = { _ in .undocumented(statusCode: 500, .init()) }

    func authExchangeToken(
        _ input: Operations.AuthExchangeToken.Input
    ) async throws -> Operations.AuthExchangeToken.Output {
        try await exchange(input)
    }

    func accountsGetMe(
        _ input: Operations.AccountsGetMe.Input
    ) async throws -> Operations.AccountsGetMe.Output {
        try await getMe(input)
    }

    func devicesCreate(
        _ input: Operations.DevicesCreate.Input
    ) async throws -> Operations.DevicesCreate.Output {
        try await createDevice(input)
    }
    func activitiesCreate(
        _ input: Operations.ActivitiesCreate.Input
    ) async throws -> Operations.ActivitiesCreate.Output {
        try await createActivity(input)
    }
    func activitiesGetTimeline(
        _ input: Operations.ActivitiesGetTimeline.Input
    ) async throws -> Operations.ActivitiesGetTimeline.Output {
        try await getTimeline(input)
    }

    func activitiesGetLabelTimeline(
        _ input: Operations.ActivitiesGetLabelTimeline.Input
    ) async throws -> Operations.ActivitiesGetLabelTimeline.Output {
        .undocumented(statusCode: 500, .init())
    }

    func activitiesGetSegmentLabelState(
        _ input: Operations.ActivitiesGetSegmentLabelState.Input
    ) async throws -> Operations.ActivitiesGetSegmentLabelState.Output {
        .undocumented(statusCode: 500, .init())
    }

    func activitiesConfirmSegmentLabels(
        _ input: Operations.ActivitiesConfirmSegmentLabels.Input
    ) async throws -> Operations.ActivitiesConfirmSegmentLabels.Output {
        .undocumented(statusCode: 500, .init())
    }

    func labelsList(
        _ input: Operations.LabelsList.Input
    ) async throws -> Operations.LabelsList.Output {
        .undocumented(statusCode: 500, .init())
    }
}

private struct RecordedRequest: Sendable {
    let request: HTTPRequest
    let hasBody: Bool
    let baseURL: URL
    let operationID: String
}

private actor RequestRecorder {
    private var values: [RecordedRequest] = []

    func record(
        request: HTTPRequest,
        hasBody: Bool,
        baseURL: URL,
        operationID: String
    ) {
        values.append(RecordedRequest(
            request: request,
            hasBody: hasBody,
            baseURL: baseURL,
            operationID: operationID
        ))
    }

    func requests() -> [RecordedRequest] {
        values
    }
}

private actor JSONBodyRecorder {
    struct Entry: Sendable {
        let request: HTTPRequest
        let operationID: String
        let body: Data
    }
    private var entries: [Entry] = []

    func record(request: HTTPRequest, operationID: String, body: Data) {
        entries.append(.init(request: request, operationID: operationID, body: body))
    }

    func requests() -> [Entry] { entries }
}

private struct RecordingClientTransport: ClientTransport {
    let sendBlock: @Sendable (
        HTTPRequest,
        HTTPBody?,
        URL,
        String
    ) async throws -> (HTTPResponse, HTTPBody?)

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await sendBlock(request, body, baseURL, operationID)
    }
}

private actor MemoryAccessTokenStore: AccessTokenStoring {
    private var token: StoredAccessToken?

    init(token: StoredAccessToken? = nil) {
        self.token = token
    }

    func load() -> StoredAccessToken? {
        token
    }

    func save(_ token: StoredAccessToken) {
        self.token = token
    }

    func delete() {
        token = nil
    }

    func currentToken() -> StoredAccessToken? {
        token
    }
}

private actor FailingDeleteTokenStore: AccessTokenStoring {
    private var deleteCalls = 0

    func load() -> StoredAccessToken? {
        StoredAccessToken(
            value: "expired-token",
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    func save(_ token: StoredAccessToken) {}

    func delete() throws {
        deleteCalls += 1
        throw MosemoAPIError.credentialStorageFailed
    }

    func deleteCallCount() -> Int {
        deleteCalls
    }
}

private actor HeaderRecorder {
    private var value: String?

    func record(_ value: String?) {
        self.value = value
    }

    func authorization() -> String? {
        value
    }
}

private actor CallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct TestTransportError: Error {}

extension MosemoAPITests {
    func testFocusSessionTransportPreservesNullableFieldsAndSendsAuthenticatedCompletion() async throws {
        let id = UUID(), deviceID = UUID(), labelID = UUID()
        let store = MemoryAccessTokenStore()
        await store.save(.init(value: "test-focus-token", expiresAt: now.addingTimeInterval(3600)))
        let recorder = JSONBodyRecorder()
        let transport = RecordingClientTransport { request, body, _, operation in
            XCTAssertEqual(request.headerFields[.authorization], "Bearer test-focus-token")
            if let body { await recorder.record(request: request, operationID: operation, body: Data(try await Array(collecting: body, upTo: 10000))) }
            let completed = operation != "focusSessionsCreate"
            let value: [String: Any] = ["sessionId": id.uuidString, "deviceId": deviceID.uuidString, "startedAt": "2026-10-07T00:00:00.123456Z", "endedAt": completed ? "2026-10-07T00:20:00.123456Z" : NSNull(), "targetSeconds": 1200, "workSeconds": completed ? 1100 : NSNull(), "labelId": completed ? labelID.uuidString : NSNull(), "description": ""]
            let response = try JSONSerialization.data(withJSONObject: operation == "focusSessionsList" ? [value] : value)
            return (HTTPResponse(status: operation == "focusSessionsCreate" ? .created : .ok, headerFields: [.contentType: "application/json"]), HTTPBody(response))
        }
        let client = makeTransportClient(tokenStore: store, transport: transport)
        let started = try await client.startFocusSession(id: id, deviceID: deviceID, startedAt: now, targetSeconds: 1200)
        XCTAssertNil(started.endedAt)
        XCTAssertNil(started.workSeconds)
        XCTAssertNil(started.labelID)
        let finished = try await client.completeFocusSession(id: id, endedAt: now.addingTimeInterval(1200), workSeconds: 1100, labelID: labelID, description: "")
        XCTAssertEqual(finished.labelID, labelID)
        XCTAssertEqual(finished.workSeconds, 1100)
        let history = try await client.listFocusSessions(date: TimelineDate(year: 2026, month: 10, day: 7))
        XCTAssertEqual(history, [finished])
        let requests = await recorder.requests()
        XCTAssertEqual(requests[0].request.path, "/api/v1/focus-sessions")
        XCTAssertEqual(requests[1].request.path, "/api/v1/focus-sessions/\(id.uuidString)/completion")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
        XCTAssertEqual(body["workSeconds"] as? Int, 1100)
        XCTAssertEqual(body["labelId"] as? String, labelID.uuidString)
        XCTAssertEqual(body["description"] as? String, "")
    }

    func testFocusSessionLiveServerLifecycleAndActivityLink() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOSEMO_FOCUS_E2E_FIXTURE"] else { throw XCTSkip("Requires disposable focus-session API fixture") }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String])
        let baseURL = try XCTUnwrap(URL(string: json["url"] ?? ""))
        let deviceID = try XCTUnwrap(UUID(uuidString: json["deviceID"] ?? ""))
        let labelID = try XCTUnwrap(UUID(uuidString: json["labelID"] ?? ""))
        let store = MemoryAccessTokenStore()
        let token = try XCTUnwrap(json["token"])
        await store.save(.init(value: token, expiresAt: .now.addingTimeInterval(3600)))
        let generated = Client(serverURL: baseURL, configuration: .init(dateTranscoder: MosemoDateTranscoder()), transport: URLSessionTransport(), middlewares: [BearerAuthenticationMiddleware(tokenStore: store, now: { .now })])
        let client = LiveMosemoAPIClient(baseURL: baseURL, anonymousClient: generated, authenticatedClient: generated, tokenStore: store, now: { .now })
        let id = UUID()
        let start = Date.now.addingTimeInterval(-120)
        let started = try await client.startFocusSession(id: id, deviceID: deviceID, startedAt: start, targetSeconds: 120)
        XCTAssertEqual(started.id, id)
        XCTAssertNil(started.endedAt)
        let retry = try await client.startFocusSession(id: id, deviceID: deviceID, startedAt: start, targetSeconds: 120)
        XCTAssertEqual(retry, started)
        let metadata = ActivityRecordMetadata(deviceRegistrationID: deviceID, eventID: UUID(), sequence: 1, observedAt: start.addingTimeInterval(10), timezoneID: "Asia/Seoul", utcOffsetMinutes: 540)
        let activity = ActivityRecord.observation(.init(metadata: metadata, context: .opaque, focusSessionID: id))
        _ = try await client.createActivity(activity)
        let finished = try await client.completeFocusSession(id: id, endedAt: start.addingTimeInterval(120), workSeconds: 100, labelID: labelID, description: "Swift client end-to-end")
        XCTAssertEqual(finished.workSeconds, 100)
        _ = try await client.createActivity(activity)
        let history = try await client.listFocusSessions(date: TimelineDate(start, timeZone: TimeZone(identifier: "Asia/Seoul")!))
        XCTAssertEqual(history, [finished])
        let labels = try await client.listLabels()
        XCTAssertTrue(labels.contains { $0.id == labelID })
    }
}
