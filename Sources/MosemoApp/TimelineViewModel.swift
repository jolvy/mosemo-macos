import Combine
import Foundation
import MosemoAPI
import SwiftUI

enum TimelineStyle: String, CaseIterable, Identifiable {
    case list = "목록"
    case timeAxis = "시간축"
    var id: Self { self }
}

enum TimelineLoadState: Equatable {
    case loading
    case loaded
    case empty
    case failed(String)
}

enum TimelinePresentationKind: Equatable {
    case detail
    case opaque
    case gap

    var label: String {
        switch self {
        case .detail: "상세 활동"
        case .opaque: "불투명 활동"
        case .gap: "수집 공백"
        }
    }

    var symbol: String {
        switch self {
        case .detail: "app.window"
        case .opaque: "eye.slash"
        case .gap: "pause.circle"
        }
    }
}

struct TimelinePresentation: Identifiable {
    let id: UUID
    let kind: TimelinePresentationKind
    let start: Date
    /// `nil` is retained for an open segment. Views must not invent a duration.
    let end: Date?
    let observedThrough: Date?
    let title: String
    let context: String

    var displayEnd: Date? {
        if let end { return end }
        return kind == .detail ? observedThrough : nil
    }

    var durationText: String {
        guard let end = displayEnd else {
            if kind == .gap { return "길이 미정" }
            return isOpen ? "종료 전" : "시각만 기록"
        }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds == 0 { return "0초" }
        if seconds < 60 { return "\(seconds)초" }
        return "\(seconds / 60)분"
    }

    var isOpen: Bool { end == nil }
    var isZeroLength: Bool { displayEnd == start }

    func timeText(timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let startText = formatter.string(from: start)
        let endText = displayEnd.map(formatter.string(from:)) ?? (kind == .detail ? "진행 중" : "종료 시각 미상")
        return "\(startText)–\(endText)"
    }
}

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var selectedDate: TimelineDate
    @Published private(set) var style: TimelineStyle = .list
    @Published private(set) var selectedSegmentID: UUID?
    @Published private(set) var loadState: TimelineLoadState = .loading
    @Published private(set) var day: TimelineDay?

    private let fetcher: any TimelineFetching
    private var store = TimelineStore()
    private var accountID: UUID
    private var requestID = UUID()
    private var requestTask: Task<Void, Never>?
    private let initialTimeZone: TimeZone

    init(
        fetcher: any TimelineFetching,
        accountID: UUID = UUID(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Seoul") ?? .current,
        now: Date = .now
    ) {
        self.fetcher = fetcher
        self.accountID = accountID
        initialTimeZone = timeZone
        selectedDate = TimelineDate(now, timeZone: timeZone)
        store.switchAccount(to: accountID)
        selectDate(selectedDate)
    }

    var timeZone: TimeZone {
        guard let identifier = day?.timeZoneID, let zone = TimeZone(identifier: identifier) else {
            return initialTimeZone
        }
        return zone
    }

    var presentations: [TimelinePresentation] {
        guard let day else { return [] }
        return day.segments.compactMap { segment in
            switch segment {
            case .activity(let activity):
                switch activity.context {
                case .opaque:
                    return TimelinePresentation(id: activity.id, kind: .opaque, start: activity.startedAt,
                                                end: activity.endedAt, observedThrough: activity.lastObservedAt,
                                                title: "알 수 없는 활동", context: "개인정보 보호로 활동 정보가 가려졌습니다")
                case .detailed(let appName, let windowTitle, let webURL):
                    // A context without any displayable attributes is intentionally omitted.
                    let values = [appName, windowTitle, webURL?.host].compactMap { $0 }.filter { !$0.isEmpty }
                    guard !values.isEmpty else { return nil }
                    let title = appName.flatMap { $0.isEmpty ? nil : $0 } ?? values[0]
                    return TimelinePresentation(id: activity.id, kind: .detail, start: activity.startedAt,
                                                end: activity.endedAt, observedThrough: activity.lastObservedAt,
                                                title: title, context: values.filter { $0 != title }.joined(separator: " · "))
                }
            case .captureGap(let gap):
                return TimelinePresentation(id: gap.id, kind: .gap, start: gap.startedAt, end: gap.endedAt,
                                            observedThrough: nil, title: "수집 공백", context: gap.reason)
            }
        }
    }

    func selectStyle(_ style: TimelineStyle) { self.style = style }

    func selectSegment(_ id: UUID?) { selectedSegmentID = id }

    func selectDate(_ date: TimelineDate) {
        guard selectedDate != date || day == nil else { return }
        selectedDate = date
        selectedSegmentID = nil
        if let cached = store.day(for: date) {
            day = cached
            loadState = presentations.isEmpty ? .empty : .loaded
            return
        }
        load(date)
    }

    func selectDate(_ date: Date) { selectDate(TimelineDate(date, timeZone: timeZone)) }

    func moveDate(by days: Int) {
        selectDate(selectedDate.adding(days: days, timeZone: timeZone))
    }

    func switchAccount(to accountID: UUID, timeZone: TimeZone? = nil) {
        guard self.accountID != accountID else { return }
        requestTask?.cancel()
        requestID = UUID()
        self.accountID = accountID
        store.switchAccount(to: accountID)
        day = nil
        selectedSegmentID = nil
        if let timeZone { selectedDate = TimelineDate(.now, timeZone: timeZone) }
        load(selectedDate)
    }

    private func load(_ date: TimelineDate) {
        requestTask?.cancel()
        let id = UUID()
        requestID = id
        day = nil
        loadState = .loading
        requestTask = Task { [weak self, fetcher] in
            do {
                let result = try await fetcher.fetch(day: date)
                guard !Task.isCancelled, let self, self.requestID == id,
                      self.selectedDate == date, result.date == date else { return }
                self.store.replace(result)
                self.day = result
                self.loadState = self.presentations.isEmpty ? .empty : .loaded
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }
}

struct TimelinePreviewFetcher: TimelineFetching {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 100_000_000) { self.delayNanoseconds = delayNanoseconds }

    func fetch(day: TimelineDate) async throws -> TimelineDay {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let today = TimelineDate(.now, timeZone: zone)
        let segments = day == today ? Self.examples(for: day, timeZone: zone) : []
        return TimelineDay(date: day, timeZoneID: zone.identifier, segments: segments)
    }

    private static func examples(for day: TimelineDate, timeZone: TimeZone) -> [TimelineSegment] {
        let start = day.startOfDay(timeZone: timeZone)
        func at(_ hour: Int, _ minute: Int) -> Date { start.addingTimeInterval(Double(hour * 60 + minute) * 60) }
        return [
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, startedAt: at(9, 0), endedAt: at(9, 42), lastObservedAt: at(9, 42), context: .detailed(appName: "Xcode", windowTitle: "MosemoApp.swift · 코드 편집", webURL: nil))),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, startedAt: at(9, 42), endedAt: at(10, 10), lastObservedAt: at(10, 10), context: .detailed(appName: "Firefox", windowTitle: "이슈 확인", webURL: URL(string: "https://github.com")))),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, startedAt: at(10, 10), endedAt: at(10, 24), lastObservedAt: at(10, 24), context: .opaque)),
            .captureGap(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, startedAt: at(10, 24), endedAt: at(10, 48), reason: "이 시간에는 활동을 관찰하지 못했습니다")),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, startedAt: at(10, 48), endedAt: at(11, 31), lastObservedAt: at(11, 31), context: .detailed(appName: "Notes", windowTitle: "작업 메모", webURL: nil))),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, startedAt: at(11, 31), endedAt: at(11, 31), lastObservedAt: at(11, 31), context: .detailed(appName: "Finder", windowTitle: nil, webURL: nil))),
            .captureGap(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, startedAt: at(12, 15), endedAt: nil, reason: "종료 시각을 아직 알 수 없습니다")),
            .activity(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!, startedAt: at(13, 0), endedAt: nil, lastObservedAt: at(13, 12), context: .detailed(appName: "Xcode", windowTitle: "열린 구간", webURL: nil)))
        ]
    }
}

struct UnavailableTimelineFetcher: TimelineFetching {
    func fetch(day: TimelineDate) async throws -> TimelineDay {
        throw NSError(domain: "Timeline", code: 1, userInfo: [NSLocalizedDescriptionKey: "타임라인 조회 기능이 연결되지 않았습니다."])
    }
}

struct TimelineScreen: View {
    @StateObject private var model: TimelineViewModel
    let accountID: UUID
    let signOut: (() -> Void)?

    init(accountID: UUID, signOut: (() -> Void)?, fetcher: any TimelineFetching = TimelineFetcherFactory.make()) {
        self.accountID = accountID
        self.signOut = signOut
        _model = StateObject(wrappedValue: TimelineViewModel(fetcher: fetcher, accountID: accountID))
    }

    var body: some View {
        TimelineView(model: model, signOut: signOut)
            .onChange(of: accountID) { _, newValue in model.switchAccount(to: newValue) }
    }
}

enum TimelineFetcherFactory {
    static func make() -> any TimelineFetching {
        #if DEBUG
        TimelinePreviewFetcher()
        #else
        UnavailableTimelineFetcher()
        #endif
    }
}
