import AppKit
import Foundation
import CollectorCore
import MosemoAPI

@MainActor
final class OfflineActivityCoordinator {
    private enum PendingPayload: Sendable {
        case observation(ActivityContext)
        case collectionStateChanged(state: CollectionStateChange.State, reason: String)

        func makeRecord(metadata: ActivityRecordMetadata) -> ActivityRecord {
            switch self {
            case .observation(let context):
                return .observation(ActivityObservation(metadata: metadata, context: context))
            case .collectionStateChanged(let state, let reason):
                return .collectionStateChanged(CollectionStateChange(
                    metadata: metadata,
                    state: state,
                    reason: reason
                ))
            }
        }
    }

    private struct PendingWrite: Sendable {
        let accountID: UUID
        let deviceID: UUID
        let generation: Int
        let observedAt: Date
        let timezoneID: String
        let utcOffsetMinutes: Int
        let payload: PendingPayload
    }

    private let queue: EncryptedActivityQueue
    private let client: any MosemoAPIClient
    private let deviceStateStore: any DeviceRegistrationStateStoring
    private var account: Account?
    private var deviceID: UUID?
    private var generation = 0
    private var isSending = false
    private var blockedGeneration: Int?
    private var blockedStatus: String?
    private var sendTask: Task<Void, Never>?
    private var pendingWrites: [PendingWrite] = []
    private var writeTask: Task<Void, Never>?
    private var storageFailureLatched = false
    private var retryAttempt = 0
    private let onStorageFailure: @MainActor () -> Void
    private let onActivityAccepted: @MainActor (UUID) -> Void
    private let onStatus: @MainActor (Int, String) -> Void
    private let sleepBeforeRetry: @Sendable (TimeInterval) async -> Void
    private let retryJitter: @Sendable () -> Double

    init(queue: EncryptedActivityQueue, client: any MosemoAPIClient,
         deviceStateStore: any DeviceRegistrationStateStoring,
         sleepBeforeRetry: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(for: .seconds(seconds))
         },
         retryJitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1.0) },
         onStorageFailure: @escaping @MainActor () -> Void = {},
         onActivityAccepted: @escaping @MainActor (UUID) -> Void = { _ in },
         onStatus: @escaping @MainActor (Int, String) -> Void) {
        self.queue = queue
        self.client = client
        self.deviceStateStore = deviceStateStore
        self.sleepBeforeRetry = sleepBeforeRetry
        self.retryJitter = retryJitter
        self.onStorageFailure = onStorageFailure
        self.onActivityAccepted = onActivityAccepted
        self.onStatus = onStatus
    }

    func activate(_ account: Account?) async {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        generation += 1
        blockedGeneration = nil
        blockedStatus = nil
        retryAttempt = 0
        let currentGeneration = generation
        self.account = account
        deviceID = nil
        guard let account else {
            let count = (try? await queue.count()) ?? 0
            guard generation == currentGeneration else { return }
            publish(count: count, status: count == 0 ? "로그인 후 전송" : "로그인 후 전송 대기")
            return
        }
        do {
            let state = try await deviceStateStore.load(for: account.id)
            guard generation == currentGeneration else { return }
            guard let deviceID = state.deviceID else {
                let count = (try? await queue.count(accountID: account.id)) ?? 0
                guard generation == currentGeneration else { return }
                publish(count: count, status: "Device 등록 필요")
                return
            }
            self.deviceID = deviceID
            await updateCount(status: "동기화 대기", expectedGeneration: currentGeneration)
            sendNext(generation: currentGeneration)
        } catch {
            guard generation == currentGeneration else { return }
            let count = (try? await queue.count(accountID: account.id)) ?? 0
            guard generation == currentGeneration else { return }
            publish(count: count, status: "저장소 확인 필요")
        }
    }

    func record(
        _ event: SafeActivityEvent,
        browserContext: TransientBrowserContext?,
        windowTitle: String? = nil,
        windowCaptureFailure: String? = nil
    ) {
        guard !storageFailureLatched, let account, let deviceID,
              shouldPersistObservation(event, browserContext: browserContext) else { return }
        let activityContext: ActivityContext
        if event.protectedContext {
            activityContext = .opaque
        } else {
            let contextUnavailable = event.observationState == .unavailable
            let appID: ActivityObservedString = contextUnavailable
                ? .absent
                : (event.appBundleID.map(ActivityObservedString.captured) ?? .absent)
            let appName: ActivityObservedString = contextUnavailable
                ? .absent
                : event.appBundleID.flatMap(Self.applicationName).map(ActivityObservedString.captured) ?? .absent
            let browser: ActivityWebContext
            if event.appBundleID == ChromeAppleEventClient.bundleID || event.appBundleID == SystemEventsClient.firefoxBundleID {
                let title = contextUnavailable ? nil : browserContext?.title.map(ActivityPrivacyFilter.title)
                let web = browserContext?.url.map(ActivityPrivacyFilter.url) ?? .unavailable(reason: "browser_context_unavailable")
                browser = .browser(ActivityBrowserContext(
                    tabTitle: title.map { .captured($0) } ?? .unavailable(
                        reason: contextUnavailable ? "observation_unavailable" : "browser_context_unavailable"
                    ),
                    url: web
                ))
            } else {
                browser = .notApplicable
            }
            activityContext = .detailed(DetailedActivityContext(
                app: ActivityApplicationContext(bundleID: appID, name: appName),
                window: windowTitle.map { .captured(title: ActivityPrivacyFilter.title($0)) }
                    ?? windowCaptureFailure.map { .unavailable(reason: $0) }
                    ?? .absent,
                web: browser
            ))
        }
        enqueueWrite(
            accountID: account.id,
            deviceID: deviceID,
            observedAt: event.occurredAt,
            payload: .observation(activityContext)
        )
    }

    private static func applicationName(for bundleID: String) -> String? {
        if let runningApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).first, let name = runningApplication.localizedName, !name.isEmpty {
            return name
        }

        guard
            let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let bundle = Bundle(url: applicationURL),
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            !name.isEmpty
        else {
            return nil
        }
        return name
    }

    func recordCollectionState(_ state: CollectionStateChange.State, reason: String) {
        guard !storageFailureLatched, let account, let deviceID else { return }
        enqueueWrite(
            accountID: account.id,
            deviceID: deviceID,
            observedAt: Date(),
            payload: .collectionStateChanged(state: state, reason: reason)
        )
    }

    private func shouldPersistObservation(
        _ event: SafeActivityEvent,
        browserContext: TransientBrowserContext?
    ) -> Bool {
        guard event.eventType == .activity else { return false }
        guard event.observationState == .unavailable else { return true }
        return browserContext?.url.map(ActivityPrivacyFilter.isEmbeddedContentURL) ?? false
    }

    private func enqueueWrite(
        accountID: UUID,
        deviceID: UUID,
        observedAt: Date,
        payload: PendingPayload
    ) {
        let timezone = TimeZone.current
        pendingWrites.append(PendingWrite(
            accountID: accountID,
            deviceID: deviceID,
            generation: generation,
            observedAt: observedAt,
            timezoneID: timezone.identifier,
            utcOffsetMinutes: timezone.secondsFromGMT(for: observedAt) / 60,
            payload: payload
        ))
        startWriterIfNeeded()
    }

    private func startWriterIfNeeded() {
        guard writeTask == nil, !pendingWrites.isEmpty, !storageFailureLatched else { return }
        writeTask = Task { [weak self] in
            await self?.drainPendingWrites()
        }
    }

    private func drainPendingWrites() async {
        while !pendingWrites.isEmpty, !storageFailureLatched {
            let pending = pendingWrites[0]
            do {
                _ = try await queue.enqueue(
                    accountID: pending.accountID,
                    deviceID: pending.deviceID,
                    observedAt: pending.observedAt,
                    timezoneID: pending.timezoneID,
                    utcOffsetMinutes: pending.utcOffsetMinutes
                ) { metadata in
                    pending.payload.makeRecord(metadata: metadata)
                }
                pendingWrites.removeFirst()
                guard generation == pending.generation else { continue }
                await updateCount(status: "동기화 대기", expectedGeneration: pending.generation)
                guard generation == pending.generation else { continue }
                sendNext(generation: pending.generation)
            } catch {
                storageFailureLatched = true
                writeTask = nil
                await publishQueueStatus(
                    accountID: pending.accountID,
                    status: "저장소 복구 필요 · 기록되지 않음",
                    expectedGeneration: pending.generation
                )
                onStorageFailure()
                return
            }
        }
        writeTask = nil
    }

    private func sendNext(generation expectedGeneration: Int) {
        guard !isSending, blockedGeneration != expectedGeneration,
              generation == expectedGeneration, let account, let deviceID else { return }
        isSending = true
        sendTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == expectedGeneration {
                let item: QueuedActivity?
                do {
                    item = try await queue.first(accountID: account.id, deviceID: deviceID)
                } catch {
                    guard generation == expectedGeneration else { return }
                    isSending = false
                    blockedGeneration = expectedGeneration
                    blockedStatus = "복구 필요 · 기록 보존 중"
                    await publishQueueStatus(accountID: account.id, status: "복구 필요 · 기록 보존 중",
                                             expectedGeneration: expectedGeneration)
                    return
                }
                guard generation == expectedGeneration, !Task.isCancelled else { return }
                guard let item else {
                    isSending = false
                    let count = (try? await queue.count(accountID: account.id)) ?? 0
                    guard generation == expectedGeneration else { return }
                    publish(count: count, status: count == 0 ? "동기화 완료" : "동기화 대기")
                    if count > 0 { sendNext(generation: expectedGeneration) }
                    return
                }
                let pendingCount = (try? await queue.count(accountID: account.id)) ?? 0
                guard generation == expectedGeneration, !Task.isCancelled else { return }
                publish(count: pendingCount, status: "활동 전송 중")
                do {
                    let result = try await client.createActivity(item.record)
                    guard generation == expectedGeneration else { return }
                    guard result.eventID == item.eventID else {
                        isSending = false
                        blockedGeneration = expectedGeneration
                        blockedStatus = "수락 확인 필요"
                        await publishQueueStatus(accountID: account.id, status: "수락 확인 필요",
                                                 expectedGeneration: expectedGeneration)
                        return
                    }
                    onActivityAccepted(account.id)
                    try await queue.acknowledge(accountID: account.id, deviceID: deviceID,
                                                sequence: item.sequence, eventID: item.eventID)
                    guard generation == expectedGeneration else { return }
                    retryAttempt = 0
                    await updateCount(status: "동기화 대기", expectedGeneration: expectedGeneration)
                } catch let error as MosemoAPIError {
                    guard generation == expectedGeneration else { return }
                    if isRetryable(error) {
                        retryAttempt += 1
                        let base = min(60.0, pow(2.0, Double(min(retryAttempt - 1, 6))))
                        let retryAfter: TimeInterval
                        if case .retryableServerError(_, let suppliedDelay) = error {
                            retryAfter = suppliedDelay ?? 0
                        } else {
                            retryAfter = 0
                        }
                        let jitter = min(1.0, max(0.5, retryJitter()))
                        let delay = max(retryAfter, base * jitter)
                        await publishQueueStatus(accountID: account.id, status: "자동 재시도 대기",
                                                 expectedGeneration: expectedGeneration)
                        await sleepBeforeRetry(delay)
                        continue
                    }
                    isSending = false
                    blockedGeneration = expectedGeneration
                    blockedStatus = "조치 필요 · 기록 보존 중"
                    await publishQueueStatus(accountID: account.id, status: "조치 필요 · 기록 보존 중",
                                             expectedGeneration: expectedGeneration)
                    return
                } catch {
                    guard generation == expectedGeneration else { return }
                    isSending = false
                    blockedGeneration = expectedGeneration
                    blockedStatus = "조치 필요 · 기록 보존 중"
                    await publishQueueStatus(accountID: account.id, status: "조치 필요 · 기록 보존 중",
                                             expectedGeneration: expectedGeneration)
                    return
                }
            }
            guard generation == expectedGeneration else { return }
            isSending = false
            await updateCount(status: "동기화 대기", expectedGeneration: expectedGeneration)
        }
    }

    private func isRetryable(_ error: MosemoAPIError) -> Bool {
        switch error {
        case .networkUnavailable, .timedOut, .serverError, .retryableServerError: true
        case .unexpectedResponse(let status): status == 408 || status == 429 || (500...599).contains(status)
        default: false
        }
    }

    private func updateCount(status: String, expectedGeneration: Int? = nil) async {
        let accountID = account?.id
        let count = (try? await queue.count(accountID: accountID)) ?? 0
        if let expectedGeneration, generation != expectedGeneration { return }
        let resolvedStatus = expectedGeneration == blockedGeneration ? (blockedStatus ?? status) : status
        publish(count: count, status: count == 0 ? "동기화 완료" : resolvedStatus)
    }

    private func publishQueueStatus(accountID: UUID, status: String, expectedGeneration: Int) async {
        let count = (try? await queue.count(accountID: accountID)) ?? 0
        guard generation == expectedGeneration else { return }
        publish(count: count, status: status)
    }

    private func publish(count: Int, status: String) { onStatus(count, status) }
}
