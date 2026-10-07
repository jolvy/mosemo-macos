import XCTest
import MosemoAPI
@testable import MosemoApp

@MainActor
final class FocusSessionTests: XCTestCase {
    func testElapsedTimeExcludesPauseAndEndsDefinitively() {
        var now: TimeInterval = 0
        let model = FocusSessionViewModel(fetchLabels: { [] }, clock: { now })
        model.start()
        now = 10
        model.pause()
        now = 100
        model.tick()
        XCTAssertEqual(model.workSeconds, 10)
        model.resume()
        now = 105
        model.end()
        XCTAssertEqual(model.workSeconds, 15)
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.displaySeconds, 0)
        model.resume()
        model.reset()
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.workSeconds, 15)
    }

    func testCountdownAutomaticallyEndsAtTarget() {
        var now: TimeInterval = 0
        let model = FocusSessionViewModel(fetchLabels: { [] }, clock: { now })
        model.timeInput = "00:20:00"
        model.start()
        now = 20
        model.tick()
        XCTAssertEqual(model.displaySeconds, 1180)
        now = 1201
        model.pause()
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.workSeconds, 1200)
        XCTAssertEqual(model.displaySeconds, 0)
    }

    func testCompletionRequiresActiveLabelAndRetainsItForNextSession() async {
        let active = LabelCatalogEntry(id: UUID(), displayName: "개발", archivedAt: nil)
        let archived = LabelCatalogEntry(id: UUID(), displayName: "보관", archivedAt: .now)
        let model = FocusSessionViewModel(fetchLabels: { [active, archived] })
        await model.loadLabels()
        XCTAssertEqual(model.labels, [active])
        model.start()
        model.end()
        model.complete()
        XCTAssertEqual(model.phase, .review)
        model.selectedLabelID = archived.id
        XCTAssertFalse(model.canComplete)
        model.selectedLabelID = active.id
        XCTAssertTrue(model.canComplete)
        model.complete()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.selectedLabelID, active.id)
        XCTAssertEqual(model.description, "")
        XCTAssertEqual(model.timeInput, "00:00:00")
        XCTAssertEqual(model.lastCompleted?.label, active)
        XCTAssertEqual(model.lastCompleted?.description, "")
    }

    func testResetClearsAllReadyInputsButCannotResetRunningSession() {
        let model = FocusSessionViewModel(fetchLabels: { [] })
        model.timeInput = "00:20:00"
        model.selectedLabelID = UUID()
        model.description = "작업 내용"
        model.start()
        model.reset()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.description, "작업 내용")
        let ready = FocusSessionViewModel(fetchLabels: { [] })
        ready.timeInput = "00:20:00"
        ready.selectedLabelID = UUID()
        ready.description = "작업 내용"
        ready.reset()
        XCTAssertEqual(ready.timeInput, "00:00:00")
        XCTAssertNil(ready.selectedLabelID)
        XCTAssertEqual(ready.description, "")
    }

    func testInvalidTimeCannotStartAndAuthenticationFailureIsReported() async {
        var authenticationFailed = false
        let model = FocusSessionViewModel(fetchLabels: { throw MosemoAPIError.authenticationRequired }, authenticationFailed: { authenticationFailed = true })
        model.timeInput = "00:60:00"
        model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.canStart)
        await model.loadLabels()
        XCTAssertTrue(authenticationFailed)
        XCTAssertNotNil(model.labelError)
        XCTAssertFalse(model.isLoadingLabels)
    }
}

@MainActor
extension FocusSessionTests {
    func testPersistedFlowExcludesPauseAndRetriesExactRequestsWithoutLosingInputs() async {
        let label = LabelCatalogEntry(id: UUID(), displayName: "개발", archivedAt: nil)
        let service = RetryingFocusService()
        var now: TimeInterval = 0
        let origin = Date(timeIntervalSince1970: 1800000000)
        var linkedIDs: [UUID?] = []
        let model = FocusSessionViewModel(fetchLabels: { [label] }, clock: { now }, service: service, deviceID: UUID(), wallClock: { origin.addingTimeInterval(now) }, activitySessionChanged: { linkedIDs.append($0) })
        await model.loadLabels()
        model.selectedLabelID = label.id
        model.description = "작업 설명"
        await model.startPersisted()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.persistenceError)
        XCTAssertFalse(model.canEditInputs)
        await model.startPersisted()
        XCTAssertEqual(model.phase, .running)
        XCTAssertNotNil(linkedIDs.last!)
        now = 10
        model.pause()
        XCTAssertNil(linkedIDs.last!)
        now = 100
        model.resume()
        XCTAssertNotNil(linkedIDs.last!)
        now = 115
        model.end()
        XCTAssertNil(linkedIDs.last!)
        XCTAssertEqual(model.workSeconds, 25)
        await model.completePersisted()
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.description, "작업 설명")
        XCTAssertEqual(model.selectedLabelID, label.id)
        XCTAssertFalse(model.canEditInputs)
        await model.completePersisted()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.selectedLabelID, label.id)
        XCTAssertEqual(model.description, "")
        XCTAssertEqual(model.history.first?.workSeconds, 25)
        XCTAssertEqual(model.history.first?.description, "작업 설명")
        let starts = await service.startRequests
        let completions = await service.completionRequests
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0], starts[1])
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(completions[0], completions[1])
    }

    func testMissingDeviceCannotStartPersistedSessionAndResetClearsPendingRetry() async {
        let service = RetryingFocusService()
        let missing = FocusSessionViewModel(fetchLabels: { [] }, service: service)
        await missing.startPersisted()
        XCTAssertEqual(missing.phase, .ready)
        XCTAssertNotNil(missing.persistenceError)
        let model = FocusSessionViewModel(fetchLabels: { [] }, service: service, deviceID: UUID())
        model.timeInput = "00:20:00"
        await model.startPersisted()
        model.reset()
        XCTAssertTrue(model.canEditInputs)
        XCTAssertNil(model.persistenceError)
        XCTAssertEqual(model.timeInput, "00:00:00")
    }
}

private actor RetryingFocusService: FocusSessionServing {
    private(set) var startRequests: [FocusSessionRecord] = []
    private(set) var completionRequests: [FocusSessionRecord] = []
    private var records: [FocusSessionRecord] = []
    func startFocusSession(id: UUID, deviceID: UUID, startedAt: Date, targetSeconds: Int) async throws -> FocusSessionRecord {
        let value = FocusSessionRecord(id: id, deviceID: deviceID, startedAt: startedAt, endedAt: nil, targetSeconds: targetSeconds, workSeconds: nil, labelID: nil, description: "")
        startRequests.append(value)
        if startRequests.count == 1 { throw MosemoAPIError.networkUnavailable }
        return value
    }
    func completeFocusSession(id: UUID, endedAt: Date, workSeconds: Int, labelID: UUID, description: String) async throws -> FocusSessionRecord {
        let start = startRequests.last!
        let value = FocusSessionRecord(id: id, deviceID: start.deviceID, startedAt: start.startedAt, endedAt: endedAt, targetSeconds: start.targetSeconds, workSeconds: workSeconds, labelID: labelID, description: description)
        completionRequests.append(value)
        records = [value]
        if completionRequests.count == 1 { throw MosemoAPIError.timedOut }
        return value
    }
    func listFocusSessions(date: TimelineDate) async throws -> [FocusSessionRecord] { records }
}

@MainActor
extension FocusSessionTests {
    func testHistoryDateSwitchRejectsOlderResponse() async {
        let service = DelayedHistoryService()
        let timezone = TimeZone(identifier: "Asia/Seoul")!
        let model = FocusSessionViewModel(fetchLabels: { [] }, service: service, timeZone: timezone)
        model.historyDate = TimelineDate(year: 2026, month: 10, day: 1).startOfDay(timeZone: timezone)
        let first = Task { await model.loadHistory() }
        for _ in 0..<100 {
            if await service.hasFirstRequest { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        model.historyDate = TimelineDate(year: 2026, month: 10, day: 2).startOfDay(timeZone: timezone)
        await model.loadHistory()
        await first.value
        XCTAssertEqual(model.history.first?.description, "day 2")
        XCTAssertFalse(model.isLoadingHistory)
        XCTAssertNil(model.historyError)
    }
}

private actor DelayedHistoryService: FocusSessionServing {
    private(set) var hasFirstRequest = false
    private(set) var hasStartRequest = false
    func listFocusSessions(date: TimelineDate) async throws -> [FocusSessionRecord] {
        if date.day == 1 { hasFirstRequest = true; try await Task.sleep(for: .milliseconds(80)) }
        return [FocusSessionRecord(id: UUID(), deviceID: UUID(), startedAt: .now, endedAt: .now, targetSeconds: 0, workSeconds: 10, labelID: UUID(), description: "day \(date.day)")]
    }
    func startFocusSession(id: UUID, deviceID: UUID, startedAt: Date, targetSeconds: Int) async throws -> FocusSessionRecord {
        hasStartRequest = true
        try await Task.sleep(for: .milliseconds(80))
        return FocusSessionRecord(id: id, deviceID: deviceID, startedAt: startedAt, endedAt: nil, targetSeconds: targetSeconds, workSeconds: nil, labelID: nil, description: "")
    }
    func completeFocusSession(id: UUID, endedAt: Date, workSeconds: Int, labelID: UUID, description: String) async throws -> FocusSessionRecord { throw MosemoAPIError.networkUnavailable }
}

@MainActor
extension FocusSessionTests {
    func testLateStartResponseAfterLeavingAccountCannotAttachSessionToCollector() async {
        let service = DelayedHistoryService()
        var attached: [UUID?] = []
        let model = FocusSessionViewModel(fetchLabels: { [] }, service: service, deviceID: UUID(), activitySessionChanged: { attached.append($0) })
        let starting = Task { await model.startPersisted() }
        for _ in 0..<100 {
            if await service.hasStartRequest { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        model.detachActivitySession()
        await starting.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(attached.allSatisfy { $0 == nil })
        XCTAssertFalse(model.isSaving)
    }
}
