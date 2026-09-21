import AppKit
import CollectorCore
import SwiftUI

struct DesktopRootView: View {
    @ObservedObject var model: CollectorViewModel
    @ObservedObject var auth: AuthCoordinator
    @Binding var onboardingCompleted: Bool

    var body: some View {
        Group {
            if !auth.hasFinishedRestoringSession {
                ProgressView("로그인 상태를 확인하는 중입니다…")
                    .controlSize(.large)
            } else if onboardingCompleted, auth.account != nil {
                ActivityDashboardView(model: model, auth: auth)
            } else {
                OnboardingView(model: model, auth: auth) {
                    onboardingCompleted = true
                }
            }
        }
        .task {
            await auth.restoreSession()
        }
    }
}

private enum OnboardingStep: Int, CaseIterable, Hashable {
    case login
    case accessibility
    case chromeAutomation

    var shortTitle: String {
        switch self {
        case .login: "로그인"
        case .accessibility: "손쉬운 사용"
        case .chromeAutomation: "Chrome"
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: CollectorViewModel
    @ObservedObject var auth: AuthCoordinator
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .login

    private var allPermissionsGranted: Bool {
        model.accessibilityPermissionGranted
            && model.automationPermission == .granted
    }

    var body: some View {
        VStack(spacing: 32) {
            OnboardingProgressView(currentStep: step)
                .frame(maxWidth: 680)

            Spacer(minLength: 12)

            stepContent
                .frame(maxWidth: 520)

            Spacer(minLength: 12)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: movePastCompletedLogin)
        .onChange(of: auth.account?.id) { _, accountID in
            if accountID == nil {
                step = .login
            } else {
                movePastCompletedLogin()
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .login:
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("Mosemo 시작하기")
                    .font(.largeTitle.bold())
                Text("카카오 계정으로 로그인해 활동 수집을 설정합니다.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(auth.isAuthenticating ? "로그인 중…" : "카카오로 로그인") {
                    auth.beginLogin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(auth.isAuthenticating)
                Text(auth.statusMessage)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

        case .accessibility:
            PermissionOnboardingStep(
                systemImage: "accessibility",
                title: "손쉬운 사용 권한",
                description: "활성 앱과 창을 확인하고 저장한 작업 화면으로 돌아가기 위해 필요합니다.",
                statusText: model.accessibilityPermissionText,
                isGranted: model.accessibilityPermissionGranted,
                requestButtonTitle: "손쉬운 사용 권한 요청",
                continueButtonTitle: "다음",
                requestPermission: model.requestAccessibilityPermission
            ) {
                step = .chromeAutomation
            }

        case .chromeAutomation:
            PermissionOnboardingStep(
                systemImage: "globe",
                title: "Chrome 자동화 권한",
                description: "Google Chrome을 먼저 실행해 주세요. 활성 창과 탭의 전환을 확인하기 위해 필요합니다.",
                statusText: model.automationPermission.rawValue,
                isGranted: model.automationPermission == .granted,
                requestInFlight: model.automationPermissionRequestInFlight,
                requestButtonTitle: "Chrome 자동화 권한 요청",
                continueButtonTitle: "완료",
                requestPermission: model.requestChromeAutomationPermission
            ) {
                guard auth.account != nil, allPermissionsGranted else { return }
                onComplete()
            }
        }
    }

    private func movePastCompletedLogin() {
        guard auth.account != nil, step == .login else { return }
        step = .accessibility
    }
}

private struct OnboardingProgressView: View {
    let currentStep: OnboardingStep

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                VStack(spacing: 8) {
                    Circle()
                        .fill(circleColor(for: step))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if step.rawValue < currentStep.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(step.rawValue + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(numberColor(for: step))
                            }
                        }
                    Text(step.shortTitle)
                        .font(.caption)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(width: 100)

                if step != OnboardingStep.allCases.last {
                    Capsule()
                        .fill(
                            step.rawValue < currentStep.rawValue
                                ? Color.accentColor
                                : Color(nsColor: .separatorColor)
                        )
                        .frame(height: 2)
                        .padding(.top, 15)
                }
            }
        }
    }

    private func circleColor(for step: OnboardingStep) -> Color {
        step.rawValue <= currentStep.rawValue
            ? .accentColor
            : Color(nsColor: .controlBackgroundColor)
    }

    private func numberColor(for step: OnboardingStep) -> Color {
        step.rawValue <= currentStep.rawValue ? .white : .secondary
    }
}

private struct PermissionOnboardingStep: View {
    let systemImage: String
    let title: String
    let description: String
    let statusText: String
    let isGranted: Bool
    var requestInFlight = false
    let requestButtonTitle: String
    let continueButtonTitle: String
    let requestPermission: () -> Void
    let continueAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text(title)
                .font(.largeTitle.bold())
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Label(
                isGranted ? "허용됨" : statusText,
                systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .foregroundStyle(isGranted ? .green : .secondary)

            Button(requestInFlight ? "요청 중…" : requestButtonTitle) {
                requestPermission()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isGranted || requestInFlight)

            Button(continueButtonTitle) {
                continueAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isGranted)
        }
    }
}

private struct ActivityDashboardView: View {
    @ObservedObject var model: CollectorViewModel
    @ObservedObject var auth: AuthCoordinator

    private var activityEvents: [DiagnosticActivityEvent] {
        Array(model.events.filter { $0.safeEvent.eventType == .activity }.reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("홈")
                        .font(.largeTitle.bold())
                    Text("활동 전환 이벤트")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(activityEvents.count)개")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("로그아웃") {
                    auth.signOut()
                }
            }

            if activityEvents.isEmpty {
                ContentUnavailableView(
                    "아직 활동 전환 이벤트가 없습니다",
                    systemImage: "list.bullet.rectangle",
                    description: Text("메뉴 막대에서 집중 세션을 시작하면 이벤트가 표시됩니다.")
                )
            } else {
                List(Array(activityEvents.enumerated()), id: \.offset) { _, record in
                    ActivityTransitionRow(record: record)
                        .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
    }
}

private struct ActivityTransitionRow: View {
    let record: DiagnosticActivityEvent

    private var event: SafeActivityEvent { record.safeEvent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event.protectedContext ? "보호된 활동" : event.transitionType.rawValue)
                    .font(.headline)
                Spacer()
                Text(event.occurredAt.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !event.protectedContext {
                Text([
                    event.appBundleID,
                    event.registeredDomain,
                    event.surfaceType.rawValue,
                    event.observationState.rawValue,
                    "\(event.detectionLatencyMilliseconds)ms",
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }
}
