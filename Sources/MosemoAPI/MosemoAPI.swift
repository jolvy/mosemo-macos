import Foundation

public protocol MosemoAPIClient: Sendable {
    func makeKakaoLoginURL(codeChallenge: String) throws -> URL

    func authenticate(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> Account

    func currentAccount() async throws -> Account
    func registerDevice(idempotencyKey: UUID) async throws -> Device
    func signOut() async throws
}
