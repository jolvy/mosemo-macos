import Foundation

public protocol MosemoAPIClient: TimelineFetching, Sendable {
    func makeKakaoLoginURL(codeChallenge: String) throws -> URL

    func authenticate(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> Account

    func currentAccount() async throws -> Account
    func registerDevice(idempotencyKey: UUID) async throws -> Device
    func createActivityBatch(_ batch: ActivityBatch) async throws -> ActivityBatchResult
    func signOut() async throws
}
