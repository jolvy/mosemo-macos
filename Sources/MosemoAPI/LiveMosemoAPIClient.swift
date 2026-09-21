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

        self.init(
            baseURL: baseURL,
            anonymousClient: Client(serverURL: baseURL, transport: transport),
            authenticatedClient: Client(
                serverURL: baseURL,
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
            lastAuthenticatedAt: response.lastAuthenticatedAt
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
