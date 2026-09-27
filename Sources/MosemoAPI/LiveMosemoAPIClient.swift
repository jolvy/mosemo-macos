import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

public struct LiveMosemoAPIClient: MosemoAPIClient {
    private let baseURL: URL
    private let anonymousClient: any APIProtocol
    private let authenticatedClient: any APIProtocol
    private let tokenStore: any AccessTokenStoring
    private let now: @Sendable () -> Date

    public init(
        baseURL: URL,
        storage: MosemoAPIStorage = .keychain
    ) throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased()),
              baseURL.host != nil else {
            throw URLError(.badURL)
        }

        let tokenStore = try storage.makeAccessTokenStore()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        let session = URLSession(configuration: sessionConfiguration)
        let transport = URLSessionTransport(configuration: .init(session: session))
        let now: @Sendable () -> Date = { Date() }
        let configuration = Configuration(dateTranscoder: MosemoDateTranscoder())

        self.init(
            baseURL: baseURL,
            anonymousClient: Client(serverURL: baseURL, configuration: configuration, transport: transport),
            authenticatedClient: Client(
                serverURL: baseURL,
                configuration: configuration,
                transport: transport,
                middlewares: [BearerAuthenticationMiddleware(
                    tokenStore: tokenStore,
                    now: now
                )]
            ),
            tokenStore: tokenStore,
            now: now
        )
    }

    init(
        baseURL: URL,
        anonymousClient: any APIProtocol,
        authenticatedClient: any APIProtocol,
        tokenStore: any AccessTokenStoring,
        now: @escaping @Sendable () -> Date
    ) {
        self.baseURL = baseURL
        self.anonymousClient = anonymousClient
        self.authenticatedClient = authenticatedClient
        self.tokenStore = tokenStore
        self.now = now
    }

    public func makeKakaoLoginURL(codeChallenge: String) throws -> URL {
        guard PKCE.isValidCodeChallenge(codeChallenge) else {
            throw URLError(.badURL)
        }

        let endpoint = baseURL.appendingPathComponent("api/v1/auth/kakao/login")
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    public func authenticate(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> Account {
        do {
            let request = Components.Schemas.TokenRequest(
                code: authorizationCode,
                codeVerifier: codeVerifier,
                grantType: .authorizationCode
            )
            let response = try await anonymousClient
                .authExchangeToken(body: .json(request))

            switch response {
            case .ok(let response):
                let token = try response.body.json
                guard !token.accessToken.isEmpty, token.expiresIn > 0 else {
                    throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                }
                try await tokenStore.save(StoredAccessToken(
                    value: token.accessToken,
                    expiresAt: now().addingTimeInterval(TimeInterval(token.expiresIn))
                ))
            case .badRequest:
                throw MosemoAPIError.invalidAuthorizationCode
            case .unprocessableContent:
                throw MosemoAPIError.validationFailed
            case .notFound:
                throw Self.error(forHTTPStatus: 404)
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }

            return try await currentAccount()
        } catch {
            throw Self.mapTokenExchange(error)
        }
    }

    public func currentAccount() async throws -> Account {
        do {
            let response = try await authenticatedClient.accountsGetMe()
            switch response {
            case .ok(let response):
                return try Self.account(from: response.body.json)
            case .unauthorized:
                throw MosemoAPIError.authenticationRequired
            case .notFound:
                throw Self.error(forHTTPStatus: 404)
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }
        } catch {
            let mappedError = Self.mapCurrentAccount(error)
            if mappedError == .authenticationRequired {
                try? await tokenStore.delete()
            }
            throw mappedError
        }
    }

    public func registerDevice(
        idempotencyKey: UUID
    ) async throws -> Device {
        do {
            let response = try await authenticatedClient.devicesCreate(
                headers: .init(idempotencyKey: idempotencyKey.uuidString)
            )
            switch response {
            case .created(let response):
                guard let id = UUID(uuidString: try response.body.json.deviceId),
                    Self.isVersion7(id)
                else {
                    throw MosemoAPIError.unexpectedResponse(statusCode: 201)
                }
                return Device(id: id)
            case .unauthorized:
                throw MosemoAPIError.authenticationRequired
            case .unprocessableContent:
                throw MosemoAPIError.validationFailed
            case .notFound:
                throw Self.error(forHTTPStatus: 404)
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }
        } catch {
            let mappedError = Self.mapDeviceCreate(error)
            if mappedError == .authenticationRequired {
                try? await tokenStore.delete()
            }
            throw mappedError
        }
    }

    public func createActivity(
        _ record: ActivityRecord
    ) async throws -> ActivityCreateResult {
        let request = try ActivityRequestMapper.request(from: record)

        do {
            let response = try await authenticatedClient.activitiesCreate(
                body: .json(request.payload)
            )
            switch response {
            case .created(let response):
                let result = try response.body.json
                guard let eventID = UUID(uuidString: result.eventId),
                      eventID == request.eventID else {
                    throw MosemoAPIError.unexpectedResponse(statusCode: 201)
                }
                return ActivityCreateResult(
                    eventID: eventID,
                    receivedAt: result.receivedAt
                )
            case .unauthorized:
                throw MosemoAPIError.authenticationRequired
            case .notFound(let response):
                let error = try response.body.json.error
                guard error.status == "ACTIVITY_DEVICE_NOT_FOUND" else {
                    throw MosemoAPIError.unexpectedResponse(statusCode: 404)
                }
                throw MosemoAPIError.activityDeviceNotFound
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .conflict(let response):
                let error = try response.body.json.error
                switch error.status {
                case "ACTIVITY_EVENT_ID_CONFLICT":
                    throw MosemoAPIError.activityEventIDConflict
                case "ACTIVITY_SEQUENCE_CONFLICT":
                    throw MosemoAPIError.activitySequenceConflict
                default:
                    throw MosemoAPIError.unexpectedResponse(statusCode: 409)
                }
            case .unprocessableContent:
                throw MosemoAPIError.validationFailed
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .serviceUnavailable:
                throw Self.error(forHTTPStatus: 503)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }
        } catch {
            let mappedError = Self.mapActivity(error)
            if mappedError == .authenticationRequired {
                try? await tokenStore.delete()
            }
            throw mappedError
        }
    }

    public func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        do {
            let response = try await authenticatedClient.activitiesGetTimeline(
                query: .init(date: day.description)
            )
            switch response {
            case .ok(let output):
                return TimelineDay(
                    date: day,
                    timeZoneID: timeZoneID,
                    segments: try TimelineResponseMapper.segments(from: output.body.json)
                )
            case .unauthorized:
                throw MosemoAPIError.authenticationRequired
            case .unprocessableContent:
                throw MosemoAPIError.validationFailed
            case .notFound:
                throw Self.error(forHTTPStatus: 404)
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }
        } catch {
            let mapped = Self.mapActivity(error)
            if mapped == .authenticationRequired {
                try? await tokenStore.delete()
            }
            throw mapped
        }
    }

    public func signOut() async throws {
        do {
            try await tokenStore.delete()
        } catch {
            throw Self.mapCommon(error, statusCode: nil)
        }
    }

    private static func account(
        from response: Components.Schemas.AccountResponse
    ) throws -> Account {
        guard let id = UUID(uuidString: response.accountId) else {
            throw MosemoAPIError.unexpectedResponse(statusCode: 200)
        }
        let provider: AccountProvider
        switch response.provider {
        case .kakao:
            provider = .kakao
        }
        return Account(
            id: id,
            provider: provider,
            createdAt: response.createdAt,
            lastAuthenticatedAt: response.lastAuthenticatedAt,
            timeZoneID: response.timezone.rawValue
        )
    }

    private static func error(
        forHTTPStatus statusCode: Int
    ) -> MosemoAPIError {
        if (500...599).contains(statusCode) {
            return MosemoAPIError.serverError(statusCode: statusCode)
        }
        return MosemoAPIError.unexpectedResponse(statusCode: statusCode)
    }

    private static func mapTokenExchange(_ error: Error) -> MosemoAPIError {
        if let clientError = error as? ClientError,
           let statusCode = clientError.response?.status.code {
            switch statusCode {
            case 400:
                return .invalidAuthorizationCode
            case 422:
                return .validationFailed
            default:
                return mapCommon(clientError, statusCode: statusCode)
            }
        }
        return mapCommon(error, statusCode: nil)
    }

    private static func mapCurrentAccount(_ error: Error) -> MosemoAPIError {
        if let clientError = error as? ClientError,
           let statusCode = clientError.response?.status.code {
            if statusCode == 401 {
                return .authenticationRequired
            }
            return mapCommon(clientError, statusCode: statusCode)
        }
        return mapCommon(error, statusCode: nil)
    }

    private static func mapDeviceCreate(_ error: Error) -> MosemoAPIError {
        if let clientError = error as? ClientError,
           let statusCode = clientError.response?.status.code {
            switch statusCode {
            case 401:
                return .authenticationRequired
            case 422:
                return .validationFailed
            default:
                return mapCommon(clientError, statusCode: statusCode)
            }
        }
        return mapCommon(error, statusCode: nil)
    }

    private static func mapActivity(_ error: Error) -> MosemoAPIError {
        if let clientError = error as? ClientError,
           let statusCode = clientError.response?.status.code {
            switch statusCode {
            case 401:
                return .authenticationRequired
            case 422:
                return .validationFailed
            default:
                return mapCommon(clientError, statusCode: statusCode)
            }
        }
        return mapCommon(error, statusCode: nil)
    }

    private static func mapCommon(
        _ error: Error,
        statusCode: Int?
    ) -> MosemoAPIError {
        if let apiError = error as? MosemoAPIError {
            return apiError
        }
        if let clientError = error as? ClientError {
            if let apiError = clientError.underlyingError as? MosemoAPIError {
                return apiError
            }
            if let urlError = clientError.underlyingError as? URLError {
                return mapURL(urlError)
            }
            if let statusCode {
                return Self.error(forHTTPStatus: statusCode)
            }
            return .unexpectedResponse(
                statusCode: clientError.response?.status.code ?? 0
            )
        }
        if let urlError = error as? URLError {
            return mapURL(urlError)
        }
        if let statusCode {
            return Self.error(forHTTPStatus: statusCode)
        }
        return .unexpectedResponse(statusCode: 0)
    }

    private static func mapURL(_ error: URLError) -> MosemoAPIError {
        error.code == .timedOut ? .timedOut : .networkUnavailable
    }

    private static func isVersion7(_ id: UUID) -> Bool {
        withUnsafeBytes(of: id.uuid) { bytes in
            bytes[6] >> 4 == 7 && bytes[8] >> 6 == 2
        }
    }
}

extension LiveMosemoAPIClient: LabelReviewReading {
    public func listLabels() async throws -> [LabelCatalogEntry] {
        do {
            let response = try await authenticatedClient.labelsList()
            switch response {
            case .ok(let result):
                return try result.body.json.map { label in
                    guard let id = UUID(uuidString: label.labelId) else {
                        throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                    }
                    return LabelCatalogEntry(
                        id: id,
                        displayName: label.displayName,
                        archivedAt: label.archivedAt
                    )
                }
            case .unauthorized:
                throw MosemoAPIError.authenticationRequired
            case .notFound:
                throw Self.error(forHTTPStatus: 404)
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }
        } catch {
            let mappedError = Self.mapCommon(error, statusCode: nil)
            if mappedError == .authenticationRequired { try? await tokenStore.delete() }
            throw mappedError
        }
    }

    public func pendingLabelSegments(day: TimelineDate) async throws -> [PendingLabelTimelineSegment] {
        do {
            let response = try await authenticatedClient.activitiesGetLabelTimeline(
                query: .init(date: day.description)
            )
            switch response {
            case .ok(let result):
                return try result.body.json.flatMap { item -> [PendingLabelTimelineSegment] in
                    guard case .activityGroup(let group) = item, group.state == .pending else {
                        return []
                    }
                    return try group.segments.map { segment in
                        guard let id = UUID(uuidString: segment.segmentId) else {
                            throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                        }
                        return PendingLabelTimelineSegment(
                            id: id,
                            version: segment.segmentVersion,
                            sourceGroupVersion: group.groupVersion,
                            startedAt: segment.startedAt,
                            endedAt: segment.endedAt,
                            appName: Self.appName(from: segment.context),
                            title: Self.title(from: segment.context)
                        )
                    }
                }
            case .unauthorized:
                throw MosemoAPIError.authenticationRequired
            case .unprocessableContent:
                throw MosemoAPIError.validationFailed
            case .notFound:
                throw Self.error(forHTTPStatus: 404)
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }
        } catch {
            let mappedError = Self.mapCommon(error, statusCode: nil)
            if mappedError == .authenticationRequired { try? await tokenStore.delete() }
            throw mappedError
        }
    }

    public func labelState(segmentID: UUID) async throws -> RemoteSegmentLabelState {
        do {
            let response = try await authenticatedClient.activitiesGetSegmentLabelState(
                path: .init(segmentId: segmentID.uuidString.lowercased())
            )
            switch response {
            case .ok(let result):
                switch try result.body.json {
                case .confirmed(let state):
                    guard let id = UUID(uuidString: state.segmentId) else {
                        throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                    }
                    return .confirmed(id: id, version: state.segmentVersion)
                case .pending(let state):
                    guard let id = UUID(uuidString: state.segmentId) else {
                        throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                    }
                    let proposal: RemoteLabelProposal
                    switch state.proposal {
                    case .ready(let ready):
                        switch ready.selection {
                        case .label(let label):
                            guard let labelID = UUID(uuidString: label.labelId) else {
                                throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                            }
                            proposal = .readyLabel(labelID)
                        case .unclassified:
                            proposal = .readyUnclassified
                        }
                    case .waiting: proposal = .waiting
                    case .processing: proposal = .processing
                    case .failed: proposal = .failed
                    }
                    return .pending(id: id, version: state.segmentVersion, proposal: proposal)
                }
            case .unauthorized:
                throw MosemoAPIError.authenticationRequired
            case .notFound:
                throw Self.error(forHTTPStatus: 404)
            case .methodNotAllowed:
                throw Self.error(forHTTPStatus: 405)
            case .conflict:
                throw Self.error(forHTTPStatus: 409)
            case .unprocessableContent:
                throw MosemoAPIError.validationFailed
            case .internalServerError:
                throw Self.error(forHTTPStatus: 500)
            case .undocumented(let statusCode, _):
                throw Self.error(forHTTPStatus: statusCode)
            }
        } catch {
            let mappedError = Self.mapCommon(error, statusCode: nil)
            if mappedError == .authenticationRequired { try? await tokenStore.delete() }
            throw mappedError
        }
    }

    private static func appName(from context: Components.Schemas.DetailedActivityContext) -> String {
        if case .captured(let name) = context.app.name, !name.value.isEmpty { return name.value }
        if case .captured(let bundle) = context.app.bundleId, !bundle.value.isEmpty { return bundle.value }
        return "알 수 없는 앱"
    }

    private static func title(from context: Components.Schemas.DetailedActivityContext) -> String {
        if case .captured(let window) = context.window, !window.title.value.isEmpty {
            return window.title.value
        }
        if case .browser(let web) = context.web,
           case .captured(let title) = web.tabTitle,
           !title.value.isEmpty {
            return title.value
        }
        return "제목 없음"
    }
}
