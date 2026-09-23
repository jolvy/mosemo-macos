import Foundation
import HTTPTypes
import OpenAPIRuntime
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
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_800_000_000)
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
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_800_000_000)
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
        await assertAPIError(.serverError(statusCode: 500)) {
            _ = try await serverClient.createActivity(record)
        }
        await assertAPIError(.serverError(statusCode: 503)) {
            _ = try await undocumentedClient.createActivity(record)
        }
        await assertAPIError(.unexpectedResponse(statusCode: 405)) {
            _ = try await methodClient.createActivity(record)
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

    let exchange: Exchange
    let getMe: GetMe
    let createDevice: DevicesCreate
    let createActivity: CreateActivity

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
