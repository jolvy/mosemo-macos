import Combine
import Foundation
import MosemoAPI

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
    var confirmedLabel: TimelineConfirmedLabel? = nil
    var details: TimelineActivity.Details? = nil

    var confirmedLabelText: String? { confirmedLabel?.displayName }
    var labelStateText: String? {
        guard kind == .detail, !isOpen else { return nil }
        return confirmedLabelText ?? "미확정"
    }
    var axisTitle: String {
        guard let confirmedLabelText else { return title }
        return confirmedLabelText + " · " + title
    }

    var displayEnd: Date? {
        end
    }

    var durationText: String {
        guard let end else {
            if kind == .gap { return "길이 미정" }
            return isOpen ? "종료 전" : "시각만 기록"
        }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds == 0 { return "0초" }
        if seconds < 60 { return "\(seconds)초" }
        return "\(seconds / 60)분"
    }

    var preciseDurationText: String {
        guard let end else { return "종료 시각 미상" }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    func detailTimeText(_ date: Date, timeZone: TimeZone, includesDate: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = includesDate ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss"
        return formatter.string(from: date)
    }

    func detailRangeText(timeZone: TimeZone) -> String {
        let startText = detailTimeText(start, timeZone: timeZone, includesDate: true)
        guard let end else { return startText + " – 종료 시각 미상" }
        let differentDay = TimelineDate(start, timeZone: timeZone) != TimelineDate(end, timeZone: timeZone)
        return startText + " – " + detailTimeText(end, timeZone: timeZone, includesDate: differentDay)
    }

    var detailTitle: String {
        let value = details?.isWeb == true ? details?.tabTitle : details?.windowTitle
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? "수집 불가"
    }

    var detailURL: String? {
        guard details?.isWeb == true else { return nil }
        return details?.webURL.flatMap { $0.isEmpty ? nil : $0 } ?? "수집 불가"
    }

    var isOpen: Bool { end == nil }
    var isZeroLength: Bool { end == start }

    func timeText(timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let startText = formatter.string(from: start)
        let endText = end.map(formatter.string(from:)) ?? (kind == .detail ? "진행 중" : "종료 시각 미상")
        return "\(startText)–\(endText)"
    }
}

struct TimelineAxis {
    static let pointsPerMinute = 1.25
    struct Tick: Identifiable {
        let id: Int
        let label: String
        let position: Double
    }
    struct Segment: Identifiable {
        let entry: TimelinePresentation
        var id: UUID { entry.id }
        let top: Double
        let height: Double
        var lane = 0
        var isShort: Bool { height < 20 }
        var visualHeight: Double { isShort ? 6 : height }
        var hitHeight: Double { max(20, height) }
    }

    let start: Date
    let end: Date
    let ticks: [Tick]
    let segments: [Segment]
    var height: Double { end.timeIntervalSince(start) / 60 * Self.pointsPerMinute }

    init(date: TimelineDate, timeZone: TimeZone, entries: [TimelinePresentation]) {
        start = date.startOfDay(timeZone: timeZone)
        end = date.adding(days: 1, timeZone: timeZone).startOfDay(timeZone: timeZone)
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var tickDate = start
        var result: [Tick] = []
        while tickDate < end {
            result.append(Tick(id: result.count, label: formatter.string(from: tickDate),
                               position: tickDate.timeIntervalSince(start) / 60 * Self.pointsPerMinute))
            tickDate = calendar.date(byAdding: .hour, value: 1, to: tickDate)!
        }
        result.append(Tick(id: result.count, label: formatter.string(from: end),
                           position: end.timeIntervalSince(start) / 60 * Self.pointsPerMinute))
        ticks = result
        let lower = start
        let upper = end
        var placed: [Segment] = entries.compactMap { entry in
            let marker = entry.isZeroLength || entry.end == nil
            guard marker ? (entry.start >= lower && entry.start < upper)
                : (entry.start < upper && entry.end! > lower) else { return nil }
            let top = max(lower, entry.start).timeIntervalSince(lower) / 60 * Self.pointsPerMinute
            let bottom = min(upper, entry.end ?? entry.start).timeIntervalSince(lower) / 60 * Self.pointsPerMinute
            return Segment(entry: entry, top: top,
                           height: marker ? 0 : min(max(5, bottom - top), upper.timeIntervalSince(lower) / 60 * Self.pointsPerMinute - top))
        }
        // Assign in time order, retaining the presentation order for callers.
        var occupiedUntil: [Double] = []
        let ordered = placed.indices.sorted {
            if placed[$0].top == placed[$1].top { return $0 < $1 }
            return placed[$0].top < placed[$1].top
        }
        for index in ordered {
            let segment = placed[index]
            let lane = occupiedUntil.firstIndex { $0 <= segment.top } ?? occupiedUntil.count
            if lane == occupiedUntil.count { occupiedUntil.append(0) }
            occupiedUntil[lane] = segment.top + max(segment.height, segment.hitHeight)
            placed[index].lane = lane
        }
        segments = placed
    }

    var laneCount: Int { (segments.map(\.lane).max() ?? 0) + 1 }

    func position(of date: Date) -> Double {
        max(0, min(height, date.timeIntervalSince(start) / 60 * Self.pointsPerMinute))
    }
}

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var selectedDate: TimelineDate
    @Published private(set) var style: TimelineStyle = .list
    @Published private(set) var selectedSegmentID: UUID?
    @Published private(set) var loadState: TimelineLoadState = .loading
    @Published private(set) var isRefreshing = false
    @Published private(set) var day: TimelineDay?
    @Published private(set) var refreshError: String?
    @Published private(set) var removedSelectionNotice = false

    private var axisOffsets: [String: Double] = [:]
    private let clock: () -> Date
    var axisKey: String { selectedDate.description + "/" + timeZone.identifier }
    var axis: TimelineAxis { TimelineAxis(date: selectedDate, timeZone: timeZone, entries: presentations) }
    var currentDate: Date { clock() }

    func initialAxisOffset(viewportHeight: Double) -> Double {
        if let saved = axisOffsets[axisKey] { return saved }
        let offset = TimelineDate(clock(), timeZone: timeZone) == selectedDate
            ? max(0, min(axis.height - viewportHeight, axis.position(of: clock()) - viewportHeight / 2)) : 0
        axisOffsets[axisKey] = offset
        return offset
    }

    func saveAxisOffset(_ offset: Double) { axisOffsets[axisKey] = max(0, offset) }

    private let fetcher: any TimelineFetching
    private var accountID: UUID
    private var requestID = UUID()
    private var uploadRefreshPending = false
    private var isRefreshingUploads = false
    private var requestTask: Task<Void, Never>?
    private var accountTimeZone: TimeZone
    private let authenticationFailed: @MainActor () -> Void

    init(
        fetcher: any TimelineFetching,
        accountID: UUID = UUID(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Seoul") ?? .current,
        now: Date = .now,
        clock: @escaping () -> Date = { .now },
        authenticationFailed: @escaping @MainActor () -> Void = {}
    ) {
        self.fetcher = fetcher
        self.clock = clock
        self.accountID = accountID
        accountTimeZone = timeZone
        self.authenticationFailed = authenticationFailed
        selectedDate = TimelineDate(now, timeZone: timeZone)
        selectDate(selectedDate)
    }

    var timeZone: TimeZone {
        guard let identifier = day?.timeZoneID, let zone = TimeZone(identifier: identifier) else {
            return accountTimeZone
        }
        return zone
    }

    var presentations: [TimelinePresentation] {
        guard let day else { return [] }
        return day.segments.map { segment in
            switch segment {
            case .activity(let activity):
                switch activity.context {
                case .opaque:
                    return TimelinePresentation(id: activity.id, kind: .opaque, start: activity.startedAt,
                                                end: activity.endedAt, observedThrough: activity.lastObservedAt,
                                                title: "알 수 없는 활동", context: "개인정보 보호로 활동 정보가 가려졌습니다")
                case .detailed(let detail):
                    let values = [detail.appName, detail.bundleID, detail.windowTitle,
                                  detail.tabTitle, detail.webURL].compactMap { $0 }.filter { !$0.isEmpty }
                    let title = values.first ?? "상세 활동"
                    return TimelinePresentation(id: activity.id, kind: .detail, start: activity.startedAt,
                                                end: activity.endedAt, observedThrough: activity.lastObservedAt,
                                                title: title, context: values.filter { $0 != title }.joined(separator: " · "),
                                                confirmedLabel: activity.confirmedLabel, details: detail)
                }
            case .captureGap(let gap):
                return TimelinePresentation(id: gap.id, kind: .gap, start: gap.startedAt, end: gap.endedAt,
                                            observedThrough: nil, title: "수집 공백", context: gap.reason)
            }
        }
    }

    func selectStyle(_ style: TimelineStyle) { self.style = style }

    func selectSegment(_ id: UUID?) {
        selectedSegmentID = id
        if id != nil { removedSelectionNotice = false }
    }

    func selectDate(_ date: TimelineDate) {
        guard selectedDate != date || day == nil else { return }
        selectedDate = date
        selectedSegmentID = nil
        removedSelectionNotice = false
        refreshError = nil
        load(date)
    }

    func selectDate(_ date: Date) { selectDate(TimelineDate(date, timeZone: timeZone)) }

    func moveDate(by days: Int) {
        selectDate(selectedDate.adding(days: days, timeZone: timeZone))
    }

    func refresh() { load(selectedDate, refreshing: true) }

    func activityUploaded() async {
        uploadRefreshPending = true
        guard !isRefreshingUploads else { return }
        isRefreshingUploads = true
        defer { isRefreshingUploads = false }
        while uploadRefreshPending {
            uploadRefreshPending = false
            refresh()
            await requestTask?.value
        }
    }

    func switchAccount(to accountID: UUID, timeZone: TimeZone? = nil) {
        guard self.accountID != accountID || (timeZone != nil && accountTimeZone != timeZone) else { return }
        requestTask?.cancel()
        requestID = UUID()
        self.accountID = accountID
        axisOffsets.removeAll()
        day = nil
        refreshError = nil
        removedSelectionNotice = false
        selectedSegmentID = nil
        if let timeZone {
            accountTimeZone = timeZone
            selectedDate = TimelineDate(clock(), timeZone: timeZone)
        }
        load(selectedDate)
    }

    private func load(_ date: TimelineDate, refreshing: Bool = false) {
        requestTask?.cancel()
        let id = UUID()
        requestID = id
        let keepsVisibleSnapshot = day?.date == date
        if !keepsVisibleSnapshot { day = nil }
        refreshError = nil
        if !keepsVisibleSnapshot { loadState = .loading }
        isRefreshing = refreshing
        let timeZoneID = timeZone.identifier
        requestTask = Task { [weak self, fetcher] in
            do {
                let result = try await fetcher.fetch(day: date, timeZoneID: timeZoneID)
                guard !Task.isCancelled, let self, self.requestID == id,
                      self.selectedDate == date, result.date == date else { return }
                if self.day != result { self.day = result }
                if let selected = self.selectedSegmentID,
                   !result.segments.contains(where: { $0.id == selected }) {
                    self.selectedSegmentID = nil
                    self.removedSelectionNotice = true
                }
                self.isRefreshing = false
                self.refreshError = nil
                self.loadState = self.presentations.isEmpty ? .empty : .loaded
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.isRefreshing = false
                if self.day?.date == date {
                    self.refreshError = Self.message(for: error)
                    self.loadState = self.presentations.isEmpty ? .empty : .loaded
                    if let apiError = error as? MosemoAPIError, apiError == .authenticationRequired {
                        self.authenticationFailed()
                    }
                    return
                }
                if let apiError = error as? MosemoAPIError, apiError == .authenticationRequired {
                    self.loadState = .failed("로그인이 필요합니다.")
                    self.authenticationFailed()
                } else {
                    self.loadState = .failed(Self.message(for: error))
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case MosemoAPIError.networkUnavailable: "서버에 연결할 수 없습니다."
        case MosemoAPIError.timedOut: "서버 응답 시간이 초과되었습니다."
        case MosemoAPIError.serverError: "서버 오류가 발생했습니다."
        default: "타임라인을 불러올 수 없습니다."
        }
    }
}
