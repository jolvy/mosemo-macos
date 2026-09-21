import Foundation
import CollectorCore
import MosemoAPI
import SwiftUI

@main
struct MosemoApp: App {
    @StateObject private var model: CollectorViewModel
    @StateObject private var auth: AuthCoordinator
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    init() {
        _model = StateObject(wrappedValue: CollectorViewModel())

        if let baseURL = AppConfiguration.apiBaseURL {
            do {
                let storage = try AppConfiguration.apiStorage()
                let client = try LiveMosemoAPIClient(
                    baseURL: baseURL,
                    storage: storage
                )
                let deviceRegistrationStateStore = try storage
                    .makeDeviceRegistrationStateStore()
                _auth = StateObject(wrappedValue: AuthCoordinator(
                    client: client,
                    deviceRegistrationStateStore: deviceRegistrationStateStore
                ))
            } catch let error as URLError where error.code == .badURL {
                _auth = StateObject(wrappedValue: AuthCoordinator(
                    client: nil,
                    configurationMessage: "API 서버 주소가 올바르지 않습니다."
                ))
            } catch {
                _auth = StateObject(wrappedValue: AuthCoordinator(
                    client: nil,
                    configurationMessage: "앱 저장소를 초기화할 수 없습니다."
                ))
            }
        } else {
            _auth = StateObject(wrappedValue: AuthCoordinator(
                client: nil,
                configurationMessage: "API 서버 주소가 설정되지 않았습니다."
            ))
        }
    }

    var body: some Scene {
        WindowGroup("Mosemo", id: "main") {
            DesktopRootView(
                model: model,
                auth: auth,
                onboardingCompleted: $onboardingCompleted
            )
            .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 900, height: 640)

        MenuBarExtra("Mosemo", systemImage: model.collectionAllowed ? "scope" : "pause.circle") {
            CollectorMenuView(model: model, auth: auth)
        }
        .menuBarExtraStyle(.window)

        Window("Collector 진단", id: "collector-diagnostics") {
            DiagnosticsView(model: model)
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 900, height: 700)
    }
}

private struct CollectorMenuView: View {
    @ObservedObject var model: CollectorViewModel
    @ObservedObject var auth: AuthCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS Collector Feasibility Spike")
                .font(.headline)

            GroupBox("계정") {
                VStack(alignment: .leading, spacing: 8) {
                    if let account = auth.account {
                        Text("카카오 계정 · \(account.id.uuidString)")
                            .font(.caption)
                            .textSelection(.enabled)
                        Button("로그아웃") { auth.signOut() }
                    } else {
                        Button("카카오로 로그인") { auth.beginLogin() }
                            .disabled(auth.isAuthenticating)
                    }
                    Text(auth.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("이번 집중 의도", text: $model.intentionDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("집중 시작") { model.startSession() }
                    .disabled(model.session.phase == .active || model.session.phase == .intendedRest)
                Button("의도된 휴식") { model.beginIntendedRest() }
                    .disabled(model.session.phase != .active)
                Button("집중 재개") { model.resumeSession() }
                    .disabled(model.session.phase != .intendedRest)
                Button("집중 종료") { model.endSession() }
                    .disabled(model.session.phase != .active && model.session.phase != .intendedRest)
            }

            HStack {
                Button("현재 화면을 복귀 지점으로") { model.markCurrentAsReturnPoint() }
                Button("복귀 테스트") { model.runReturnTest() }
            }
            .disabled(!model.collectionAllowed)

            Divider()
            Text("상태: \(model.statusMessage)")
                .font(.caption)
                .lineLimit(3)
            Text("복귀 지점: \(model.currentAnchorText)")
                .font(.caption)

            HStack {
                Button("앱 열기", action: openApp)
                Button("진단 열기", action: openDiagnostics)
                Spacer()
                Button("종료") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func openApp() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }

    private func openDiagnostics() {
        openWindow(id: "collector-diagnostics")
        DispatchQueue.main.async {
            NSApplication.shared.activate()
            NSApplication.shared.windows
                .first { $0.title == "Collector 진단" }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

private enum AppConfiguration {
    static var apiBaseURL: URL? {
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "MosemoAPIBaseURL"
        ) as? String,
           !value.isEmpty,
           !value.contains("$("),
           let url = URL(string: value) {
            return url
        }

        #if DEBUG
        return URL(string: "http://localhost:8000")
        #else
        return nil
        #endif
    }

    static func apiStorage() throws -> MosemoAPIStorage {
        #if DEBUG
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = applicationSupport.appendingPathComponent(
            "io.mosemo.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
        return .sqlite(
            databaseURL: appDirectory.appendingPathComponent(
                "local-state.sqlite",
                isDirectory: false
            )
        )
        #else
        return .keychain
        #endif
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: CollectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("수집 상태와 성능")
                    .font(.title2.bold())
                Spacer()
                Button("안전 진단 복사") { model.copySafeDiagnostics() }
            }

            GroupBox("권한") {
                HStack(spacing: 24) {
                    permission(
                        "System Events 자동화",
                        value: model.systemEventsAutomationPermission.rawValue,
                        buttonTitle: "System Events 권한 요청"
                    ) {
                        model.requestSystemEventsAutomationPermission()
                    }
                    VStack(alignment: .leading) {
                        Text("Chrome 자동화: \(model.chromeAutomationPermission.rawValue)")
                        Button("Chrome 자동화 권한 요청") {
                            model.requestChromeAutomationPermission()
                        }
                        .disabled(model.chromeAutomationPermissionRequestInFlight)
                        Text("Chrome을 먼저 실행하세요. 집중 시작 전에도 권한만 요청할 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("측정") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 24) {
                        metric("CPU 현재", String(format: "%.2f%%", model.currentCPUPercent))
                        metric("CPU 실행 평균", String(format: "%.2f%%", model.averageCPUPercent))
                        metric("메모리 현재", megabytes(model.currentMemoryBytes))
                        metric("메모리 최대", megabytes(model.maximumMemoryBytes))
                    }
                    HStack(spacing: 24) {
                        metric("감지", "\(model.statistics.detectedTransitions)")
                        metric("의도 전환", "\(model.statistics.expectedTransitions)")
                        metric("일치", "\(model.statistics.matchedExpectedTransitions)")
                        metric("누락", "\(model.statistics.missedTransitions)")
                        metric("p95 지연", model.statistics.p95LatencyMilliseconds.map { "\($0) ms" } ?? "미측정")
                        metric("관찰 불가", "\(model.statistics.observationFailures)")
                    }
                    HStack {
                        Button("다음 앱 전환") { model.markExpectedAppTransition() }
                            .disabled(!model.collectionAllowed)
                        Button("다음 Chrome 전환") { model.markExpectedChromeTransition() }
                            .disabled(!model.collectionAllowed)
                        Button("다음 Firefox 변화") { model.markExpectedFirefoxTransition() }
                            .disabled(!model.collectionAllowed)
                        Button("전환 통계 초기화") { model.resetMeasurementStatistics() }
                        Text("수동 기준점 지연에는 사용자의 전환 동작 시간이 포함됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("메모리 ring buffer · 최근 \(model.events.count)/600 이벤트")
                .font(.headline)
            Text("테스트 모드: 일반 Chrome·Firefox의 탭 제목과 전체 URL이 앱 메모리에 노출됩니다. 안전 진단 복사에는 포함되지 않으며 앱 종료 또는 새 집중 시작 때 사라집니다.")
                .font(.caption)
                .foregroundStyle(.orange)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.events.enumerated().reversed()), id: \.offset) { _, record in
                        SafeEventRow(record: record)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func permission(
        _ name: String,
        value: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading) {
            Text("\(name): \(value)")
            Button(buttonTitle, action: action)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

private struct SafeEventRow: View {
    let record: DiagnosticActivityEvent

    private var event: SafeActivityEvent { record.safeEvent }

    var body: some View {
        if event.protectedContext {
            Text("\(event.occurredAt.formatted()) · 보호된 활동")
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text([
                    event.occurredAt.formatted(),
                    event.appBundleID ?? "-",
                    event.registeredDomain ?? "-",
                    event.surfaceType.rawValue,
                    event.transitionType.rawValue,
                    event.observationState.rawValue,
                    event.inputOccurred.map { "input=\($0)" } ?? "",
                    "\(event.detectionLatencyMilliseconds)ms",
                ].filter { !$0.isEmpty }.joined(separator: " · "))

                if let context = record.browserContext {
                    Text("title=\(context.title ?? "관찰 불가")")
                        .foregroundStyle(.secondary)
                    Text("url=\(context.url ?? "관찰 불가")")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 8)
        }
    }
}
