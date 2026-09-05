import CryptoKit
import Foundation
import Security

public enum PKCEError: Error, Equatable, Sendable {
    case randomGenerationFailed
    case invalidCodeVerifier
}

public enum PKCE {
    public static func makeCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PKCEError.randomGenerationFailed
        }
        return Data(bytes).base64URLEncodedString()
    }

    public static func codeChallenge(for codeVerifier: String) throws -> String {
        guard isValidCodeVerifier(codeVerifier),
              let data = codeVerifier.data(using: .ascii) else {
            throw PKCEError.invalidCodeVerifier
        }
        return Data(SHA256.hash(data: data)).base64URLEncodedString()
    }

    static func isValidCodeChallenge(_ value: String) -> Bool {
        value.count == 43 && value.unicodeScalars.allSatisfy {
            codeChallengeCharacters.contains($0)
        }
    }

    private static func isValidCodeVerifier(_ value: String) -> Bool {
        (43...128).contains(value.count) && value.unicodeScalars.allSatisfy {
            codeVerifierCharacters.contains($0)
        }
    }

    private static let codeChallengeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    private static let codeVerifierCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
