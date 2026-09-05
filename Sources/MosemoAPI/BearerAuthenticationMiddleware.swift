import Foundation
import HTTPTypes
import OpenAPIRuntime

struct BearerAuthenticationMiddleware: ClientMiddleware {
    let tokenStore: any AccessTokenStoring
    let now: @Sendable () -> Date

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (
            HTTPResponse,
            HTTPBody?
        )
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let token = try await tokenStore.load() else {
            throw MosemoAPIError.authenticationRequired
        }
        guard token.expiresAt > now() else {
            try await tokenStore.delete()
            throw MosemoAPIError.authenticationRequired
        }

        var authenticatedRequest = request
        authenticatedRequest.headerFields[.authorization] = "Bearer \(token.value)"
        return try await next(authenticatedRequest, body, baseURL)
    }
}
