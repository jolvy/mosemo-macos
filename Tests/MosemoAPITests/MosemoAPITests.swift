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
                    provider: .kakao
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
            .badRequest(.init(body: .json(.init(detail: "changed message"))))
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
            .unprocessableContent(.init(body: .json(.init(detail: []))))
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
                operationID: "exchange_token_api_v1_auth_token_post",
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
                .unauthorized(.init(body: .json(.init(detail: "unauthorized"))))
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
                    operationID: "get_me_api_v1_accounts_me_get",
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
        tokenStore: MemoryAccessTokenStore = MemoryAccessTokenStore(),
        exchange: @escaping MockGeneratedAPI.Exchange = { _ in
            .undocumented(statusCode: 500, .init())
        },
        getMe: @escaping MockGeneratedAPI.GetMe = { _ in
            .undocumented(statusCode: 500, .init())
        }
    ) -> LiveMosemoAPIClient {
        LiveMosemoAPIClient(
            baseURL: baseURL,
            anonymousClient: MockGeneratedAPI(exchange: exchange, getMe: getMe),
            authenticatedClient: MockGeneratedAPI(exchange: exchange, getMe: getMe),
            tokenStore: tokenStore,
            now: { self.now }
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

private struct MockGeneratedAPI: APIProtocol {
    typealias Exchange = @Sendable (
        Operations.ExchangeTokenApiV1AuthTokenPost.Input
    ) async throws -> Operations.ExchangeTokenApiV1AuthTokenPost.Output
    typealias GetMe = @Sendable (
        Operations.GetMeApiV1AccountsMeGet.Input
    ) async throws -> Operations.GetMeApiV1AccountsMeGet.Output

    let exchange: Exchange
    let getMe: GetMe

    func exchangeTokenApiV1AuthTokenPost(
        _ input: Operations.ExchangeTokenApiV1AuthTokenPost.Input
    ) async throws -> Operations.ExchangeTokenApiV1AuthTokenPost.Output {
        try await exchange(input)
    }

    func getMeApiV1AccountsMeGet(
        _ input: Operations.GetMeApiV1AccountsMeGet.Input
    ) async throws -> Operations.GetMeApiV1AccountsMeGet.Output {
        try await getMe(input)
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

private actor HeaderRecorder {
    private var value: String?

    func record(_ value: String?) {
        self.value = value
    }

    func authorization() -> String? {
        value
    }
}

private struct TestTransportError: Error {}
