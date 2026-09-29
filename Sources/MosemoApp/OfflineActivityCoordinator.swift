import Foundation
import CollectorCore
import MosemoAPI

@MainActor
final class OfflineActivityCoordinator {
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
    private var retryAttempt = 0
    private let onStatus: @MainActor (Int, String) -> Void
    private let sleepBeforeRetry: @Sendable (TimeInterval) async -> Void
    private let retryJitter: @Sendable () -> Double

    init(queue: EncryptedActivityQueue, client: any MosemoAPIClient,
         deviceStateStore: any DeviceRegistrationStateStoring,
         sleepBeforeRetry: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(for: .seconds(seconds))
         },
         retryJitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1.0) },
         onStatus: @escaping @MainActor (Int, String) -> Void) {
        self.queue = queue
        self.client = client
        self.deviceStateStore = deviceStateStore
        self.sleepBeforeRetry = sleepBeforeRetry
        self.retryJitter = retryJitter
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

    func record(_ event: SafeActivityEvent, browserContext: TransientBrowserContext?) {
        let embeddedContentURL = browserContext?.url.map(ActivityPrivacyFilter.isEmbeddedContentURL) ?? false
        guard let account, let deviceID, event.eventType == .activity,
              event.observationState != .unavailable || embeddedContentURL else { return }
        let activityContext: ActivityContext
        if event.protectedContext {
            activityContext = .opaque
        } else {
            let contextUnavailable = event.observationState == .unavailable
            let appID: ActivityObservedString = contextUnavailable
                ? .absent
                : (event.appBundleID.map(ActivityObservedString.captured) ?? .absent)
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
                app: ActivityApplicationContext(bundleID: appID, name: .absent),
                window: .absent,
                web: browser
            ))
        }
        let recordGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let timezone = TimeZone.current
                _ = try await queue.enqueue(accountID: account.id, deviceID: deviceID,
                    observedAt: event.occurredAt, timezoneID: timezone.identifier,
                    utcOffsetMinutes: timezone.secondsFromGMT(for: event.occurredAt) / 60) { metadata in
                    .observation(ActivityObservation(metadata: metadata, context: activityContext))
                }
                await updateCount(status: "동기화 대기", expectedGeneration: recordGeneration)
                guard generation == recordGeneration else { return }
                sendNext(generation: recordGeneration)
            } catch {
                await publishQueueStatus(accountID: account.id, status: "기록 저장 실패 · 확인 필요",
                                         expectedGeneration: recordGeneration)
            }
        }
    }

    func recordCollectionState(_ state: CollectionStateChange.State, reason: String) {
        guard let account, let deviceID else { return }
        let recordGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let observedAt = Date()
                let timezone = TimeZone.current
                _ = try await queue.enqueue(accountID: account.id, deviceID: deviceID,
                    observedAt: observedAt, timezoneID: timezone.identifier,
                    utcOffsetMinutes: timezone.secondsFromGMT(for: observedAt) / 60) { metadata in
                    .collectionStateChanged(CollectionStateChange(metadata: metadata, state: state, reason: reason))
                }
                await updateCount(status: "동기화 대기", expectedGeneration: recordGeneration)
                guard generation == recordGeneration else { return }
                sendNext(generation: recordGeneration)
            } catch {
                await publishQueueStatus(accountID: account.id, status: "기록 저장 실패 · 확인 필요",
                                         expectedGeneration: recordGeneration)
            }
        }
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
