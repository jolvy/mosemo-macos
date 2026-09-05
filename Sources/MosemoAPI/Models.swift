import Foundation

public enum AccountProvider: String, Equatable, Sendable {
    case kakao
}

public struct Account: Equatable, Sendable {
    public let id: UUID
    public let provider: AccountProvider
    public let createdAt: Date
    public let lastAuthenticatedAt: Date

    public init(
        id: UUID,
        provider: AccountProvider,
        createdAt: Date,
        lastAuthenticatedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.createdAt = createdAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }
}
