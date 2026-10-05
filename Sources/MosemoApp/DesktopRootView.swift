import AppKit
import CollectorCore
import Combine
import MosemoAPI
import SwiftUI

struct DesktopRootView: View {
    @ObservedObject var model: CollectorViewModel
    @ObservedObject var auth: AuthCoordinator
    let timelineClient: LiveMosemoAPIClient?
    let reviewReader: (any LabelReviewReading)?
    @Binding var onboardingCompleted: Bool

    var body: some View {
        Group {
            if !auth.hasFinishedRestoringSession {
                ProgressView("로그인 상태를 확인하는 중입니다…")
                    .controlSize(.large)
            } else if onboardingCompleted, let account = auth.account,
                      let timelineClient, let reviewReader {
                MainWorkspaceView(
                    account: account,
                    timelineFetcher: timelineClient,
                    reviewFetcher: LiveLabelReviewFetcher(reader: reviewReader),
                    reviewWriter: timelineClient,
                    signOut: auth.signOut,
                    acceptedActivityUploads: model.acceptedActivityUploads.eraseToAnyPublisher(),
                    authenticationFailed: { auth.timelineAuthenticationFailed(for: account.id) }
                )
                .id("\(account.id):\(account.timeZoneID)")
            } else {
                OnboardingView(model: model, auth: auth) {
                    onboardingCompleted = true
                }
            }
        }
        .task {
            await auth.restoreSession()
        }
        .task(id: "\(auth.account?.id.uuidString ?? ""):\(auth.registeredDeviceID?.uuidString ?? "")") {
            await model.synchronizationAccountChanged(auth.account)
        }
    }
}

private enum WorkspacePage: Hashable {
    case timeline
    case labelReview
    case activityChat

    var title: String {
        switch self {
        case .timeline: "관찰 타임라인"
        case .labelReview: "라벨 검토"
        case .activityChat: "AI 채팅"
        }
    }

    var symbol: String {
        switch self {
        case .timeline: "calendar"
        case .labelReview: "checkmark.rectangle.stack"
        case .activityChat: "sparkles"
        }
    }
}

struct MainWorkspaceView: View {
    @State private var selectedPage: WorkspacePage = .timeline
    @StateObject private var timelineModel: TimelineViewModel
    @StateObject private var reviewModel: LabelReviewViewModel
    @StateObject private var chatModel = ActivityChatViewModel()

    private let accountID: UUID
    private let acceptedActivityUploads: AnyPublisher<UUID, Never>
    private let previewUpload: (() -> Void)?
    let signOut: (() -> Void)?
    let showsPreviewNotice: Bool

    init(
        account: Account,
        timelineFetcher: any TimelineFetching,
        reviewFetcher: any LabelReviewFetching,
        reviewWriter: any LabelConfirmationWriting,
        signOut: (() -> Void)?,
        acceptedActivityUploads: AnyPublisher<UUID, Never> = Empty().eraseToAnyPublisher(),
        previewUpload: (() -> Void)? = nil,
        authenticationFailed: @escaping @MainActor () -> Void = {},
        showsPreviewNotice: Bool = false,
        timelineNow: Date? = nil,
        showsActivityChatInitially: Bool = false
    ) {
        _selectedPage = State(initialValue: showsActivityChatInitially ? .activityChat : .timeline)
        self.accountID = account.id
        self.acceptedActivityUploads = acceptedActivityUploads
        self.previewUpload = previewUpload
        self.signOut = signOut
        self.showsPreviewNotice = showsPreviewNotice
        let timeZone = TimeZone(identifier: account.timeZoneID) ?? .current
        _timelineModel = StateObject(wrappedValue: TimelineViewModel(
            fetcher: timelineFetcher,
            accountID: account.id,
            timeZone: timeZone,
            now: timelineNow ?? .now,
            clock: { timelineNow ?? .now },
            authenticationFailed: authenticationFailed
        ))
        _reviewModel = StateObject(wrappedValue: LabelReviewViewModel(
            fetcher: reviewFetcher,
            writer: reviewWriter,
            timeZone: timeZone
        ))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Group {
                switch selectedPage {
                case .timeline:
                    TimelineView(model: timelineModel, showsPreviewNotice: showsPreviewNotice, previewUpload: previewUpload)
                case .labelReview:
                    LabelReviewView(viewModel: reviewModel)
                case .activityChat:
                    ActivityChatView(model: chatModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 520)
        .onReceive(acceptedActivityUploads) { uploadedAccountID in
            guard uploadedAccountID == accountID else { return }
            Task { await timelineModel.activityUploaded() }
            Task { await reviewModel.activityUploaded() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(.mint)
                Text("MOSEMO")
                    .font(.headline.weight(.bold))
                    .tracking(2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 25)
            .padding(.bottom, 35)

            Text("화면")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.bottom, 9)

            pageButton(.timeline)
            pageButton(.labelReview)
            pageButton(.activityChat)

            Spacer()

            if let signOut {
                Divider().overlay(.white.opacity(0.15))
                    .padding(.bottom, 10)
                Button(action: signOut) {
                    Label("로그아웃", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityIdentifier("workspace-sign-out")
            }
        }
        .frame(width: 205)
        .frame(maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.09, blue: 0.12))
    }

    private func pageButton(_ page: WorkspacePage) -> some View {
        Button {
            selectedPage = page
        } label: {
            Label(page.title, systemImage: page.symbol)
                .font(.subheadline.weight(selectedPage == page ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    selectedPage == page ? Color.white.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedPage == page ? .white : .white.opacity(0.68))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .accessibilityIdentifier({
            switch page {
            case .timeline: "navigation-timeline"
            case .labelReview: "navigation-label-review"
            case .activityChat: "navigation-activity-chat"
            }
        }())
    }
}

private enum OnboardingStep: Int, CaseIterable, Hashable {
    case login
    case systemEventsAutomation
    case chromeAutomation

    var shortTitle: String {
        switch self {
        case .login: "로그인"
        case .systemEventsAutomation: "System Events"
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
        model.systemEventsAutomationPermission == .granted
            && model.chromeAutomationPermission == .granted
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

        case .systemEventsAutomation:
            PermissionOnboardingStep(
                systemImage: "gearshape.2",
                title: "System Events 자동화 권한",
                description: "Firefox의 활성 탭 제목과 URL을 읽기 위해 필요합니다. Firefox를 먼저 실행해 주세요.",
                statusText: model.systemEventsAutomationPermission.rawValue,
                isGranted: model.systemEventsAutomationPermission == .granted,
                requestInFlight: model.systemEventsPermissionRequestInFlight,
                requestButtonTitle: "System Events 권한 요청",
                continueButtonTitle: "다음",
                requestPermission: model.requestSystemEventsAutomationPermission
            ) {
                step = .chromeAutomation
            }

        case .chromeAutomation:
            PermissionOnboardingStep(
                systemImage: "globe",
                title: "Chrome 자동화 권한",
                description: "Google Chrome을 먼저 실행해 주세요. 활성 창과 탭의 전환을 확인하기 위해 필요합니다.",
                statusText: model.chromeAutomationPermission.rawValue,
                isGranted: model.chromeAutomationPermission == .granted,
                requestInFlight: model.chromeAutomationPermissionRequestInFlight,
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
        step = .systemEventsAutomation
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
