public enum MosemoAPIError: Error, Equatable, Sendable {
    case authenticationRequired
    case invalidAuthorizationCode
    case validationFailed
    case activityDeviceNotFound
    case activityEventIDConflict
    case activitySequenceConflict
    case serverError(statusCode: Int)
    case networkUnavailable
    case timedOut
    case unexpectedResponse(statusCode: Int)
    case credentialStorageFailed
}
