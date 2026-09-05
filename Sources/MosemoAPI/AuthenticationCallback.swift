import Foundation

public enum AuthenticationCallbackError: Error, Equatable, Sendable {
    case cancelled
    case authenticationFailed
    case invalidCallback
}

public enum AuthenticationCallback {
    public static let scheme = "io.mosemo.app"
    public static let path = "/auth/callback"

    public static func authorizationCode(from url: URL) throws -> String {
        guard url.scheme == scheme,
              url.host == nil,
              url.path == path,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ) else {
            throw AuthenticationCallbackError.invalidCallback
        }

        let items = components.queryItems ?? []
        let errorValues = items.filter { $0.name == "error" }
        if errorValues.count == 1 {
            if errorValues[0].value == "access_denied" {
                throw AuthenticationCallbackError.cancelled
            }
            throw AuthenticationCallbackError.authenticationFailed
        }
        guard errorValues.isEmpty else {
            throw AuthenticationCallbackError.invalidCallback
        }

        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1,
              let code = codes[0].value,
              !code.isEmpty else {
            throw AuthenticationCallbackError.invalidCallback
        }
        return code
    }
}
