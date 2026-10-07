import Foundation

public enum MosemoAPIError: Error, Equatable, Sendable {
    case focusSessionNotFound
    case focusSessionConflict
    case authenticationRequired
    case invalidAuthorizationCode
    case validationFailed
    case deviceRegistrationRequired
    case activityDeviceNotFound
    case activityEventIDConflict
    case activitySequenceConflict
    case serverError(statusCode: Int)
    case retryableServerError(statusCode: Int, retryAfter: TimeInterval?)
    case networkUnavailable
    case timedOut
    case unexpectedResponse(statusCode: Int)
    case credentialStorageFailed
    case activityQueueStorageFailed
}
