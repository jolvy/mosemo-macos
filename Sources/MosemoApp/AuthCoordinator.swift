import AppKit
import AuthenticationServices
import Combine
import Foundation
import MosemoAPI

@MainActor
final class AuthCoordinator: NSObject, ObservableObject {
    @Published private(set) var account: Account?
    @Published private(set) var statusMessage: String
    @Published private(set) var isAuthenticating = false

    private let client: (any MosemoAPIClient)?
    private let deviceRegistrationManager: DeviceRegistrationManager
    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var pendingCodeVerifier: String?
    private var hasRestoredSession = false

    private lazy var fallbackPresentationWindow = NSWindow(
        contentRect: .zero,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )

    init(
        client: (any MosemoAPIClient)?,
        configurationMessage: String? = nil,
        deviceRegistrationStateStore: any DeviceRegistrationStateStoring =
            KeychainDeviceRegistrationStateStore()
    ) {
        self.client = client
        deviceRegistrationManager = DeviceRegistrationManager(
            stateStore: deviceRegistrationStateStore
        )
        statusMessage = configurationMessage ?? "로그인이 필요합니다."
        super.init()
    }

    func restoreSession() async {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true

        guard let client else { return }
        do {
            let restoredAccount = try await client.currentAccount()
            await completeAuthentication(
                restoredAccount,
                using: client,
                successMessage: "로그인되어 있습니다."
            )
        } catch MosemoAPIError.authenticationRequired {
            account = nil
            statusMessage = "로그인이 필요합니다."
        } catch {
            account = nil
            statusMessage = Self.message(for: error)
        }
    }

    func beginLogin() {
        guard !isAuthenticating else {
            statusMessage = "이미 로그인을 진행하고 있습니다."
            return
        }
        guard let client else {
            statusMessage = "API 서버 주소가 설정되지 않았습니다."
            return
        }

        do {
            let verifier = try PKCE.makeCodeVerifier()
            let challenge = try PKCE.codeChallenge(for: verifier)
            let loginURL = try client.makeKakaoLoginURL(codeChallenge: challenge)

            pendingCodeVerifier = verifier
            isAuthenticating = true
            statusMessage = "카카오 로그인을 기다리고 있습니다."

            let session = ASWebAuthenticationSession(
                url: loginURL,
                callbackURLScheme: AuthenticationCallback.scheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    await self?.finishLogin(callbackURL: callbackURL, error: error)
                }
            }
            session.presentationContextProvider = self
            webAuthenticationSession = session

            guard session.start() else {
                clearPendingLogin()
                statusMessage = "로그인 창을 열 수 없습니다."
                return
            }
        } catch {
            clearPendingLogin()
            statusMessage = Self.message(for: error)
        }
    }

    func signOut() {
        guard let client else {
            account = nil
            statusMessage = "로그아웃했습니다."
            return
        }

        Task {
            do {
                try await client.signOut()
                account = nil
                statusMessage = "로그아웃했습니다."
            } catch {
                statusMessage = Self.message(for: error)
            }
        }
    }

    private func finishLogin(callbackURL: URL?, error: Error?) async {
        guard isAuthenticating, let verifier = pendingCodeVerifier else {
            clearPendingLogin()
            return
        }
        clearPendingLogin()

        if let error {
            let cocoaError = error as NSError
            if cocoaError.domain == ASWebAuthenticationSessionError.errorDomain,
               cocoaError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                statusMessage = "로그인을 취소했습니다."
            } else {
                statusMessage = "로그인 창에서 오류가 발생했습니다."
            }
            return
        }

        guard let callbackURL, let client else {
            statusMessage = "로그인 콜백이 올바르지 않습니다."
            return
        }

        do {
            let authorizationCode = try AuthenticationCallback
                .authorizationCode(from: callbackURL)
            let authenticatedAccount = try await client.authenticate(
                authorizationCode: authorizationCode,
                codeVerifier: verifier
            )
            await completeAuthentication(
                authenticatedAccount,
                using: client,
                successMessage: "로그인했습니다."
            )
        } catch AuthenticationCallbackError.cancelled {
            statusMessage = "로그인을 취소했습니다."
        } catch {
            account = nil
            statusMessage = Self.message(for: error)
        }
    }

    private func completeAuthentication(
        _ authenticatedAccount: Account,
        using client: any MosemoAPIClient,
        successMessage: String
    ) async {
        account = authenticatedAccount
        do {
            _ = try await deviceRegistrationManager.ensureRegistered(
                for: authenticatedAccount,
                using: client
            )
            statusMessage = successMessage
        } catch MosemoAPIError.authenticationRequired {
            account = nil
            statusMessage = "로그인이 필요합니다."
        } catch {
            statusMessage = "Device 등록에 실패했습니다. 다시 시도해 주세요."
        }
    }

    private func clearPendingLogin() {
        webAuthenticationSession = nil
        pendingCodeVerifier = nil
        isAuthenticating = false
    }

    private static func message(for error: Error) -> String {
        switch error {
        case MosemoAPIError.authenticationRequired:
            return "로그인이 필요합니다."
        case MosemoAPIError.invalidAuthorizationCode:
            return "로그인 코드가 만료되었거나 이미 사용되었습니다."
        case MosemoAPIError.validationFailed:
            return "로그인 요청이 올바르지 않습니다."
        case MosemoAPIError.serverError:
            return "서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요."
        case MosemoAPIError.networkUnavailable:
            return "서버에 연결할 수 없습니다."
        case MosemoAPIError.timedOut:
            return "서버 응답 시간이 초과되었습니다."
        case MosemoAPIError.unexpectedResponse:
            return "예상하지 못한 서버 응답을 받았습니다."
        case MosemoAPIError.credentialStorageFailed:
            return "로그인 정보를 안전하게 저장할 수 없습니다."
        case AuthenticationCallbackError.cancelled:
            return "로그인을 취소했습니다."
        case AuthenticationCallbackError.authenticationFailed:
            return "카카오 인증에 실패했습니다."
        case AuthenticationCallbackError.invalidCallback:
            return "로그인 콜백이 올바르지 않습니다."
        default:
            return "로그인을 처리할 수 없습니다."
        }
    }
}

extension AuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? fallbackPresentationWindow
    }
}
