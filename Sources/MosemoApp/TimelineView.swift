import SwiftUI
import MosemoAPI

struct TimelineScreen: View {
    @StateObject private var model: TimelineViewModel
    let account: Account
    let signOut: (() -> Void)?
    let showsPreviewNotice: Bool

    init(
        account: Account,
        signOut: (() -> Void)?,
        authenticationFailed: @escaping @MainActor () -> Void = {},
        fetcher: any TimelineFetching,
        showsPreviewNotice: Bool = false
    ) {
        self.account = account
        self.signOut = signOut
        self.showsPreviewNotice = showsPreviewNotice
        _model = StateObject(wrappedValue: TimelineViewModel(
            fetcher: fetcher,
            accountID: account.id,
            timeZone: TimeZone(identifier: account.timeZoneID)!,
            authenticationFailed: authenticationFailed
        ))
    }

    var body: some View {
        TimelineView(model: model, signOut: signOut, showsPreviewNotice: showsPreviewNotice)
            .onChange(of: account) { _, newAccount in
                model.switchAccount(
                    to: newAccount.id,
                    timeZone: TimeZone(identifier: newAccount.timeZoneID)
                )
            }
    }
}

struct TimelineView: View {
    @ObservedObject var model: TimelineViewModel
    let signOut: (() -> Void)?
    let showsPreviewNotice: Bool
    @Environment(\.openWindow) private var openWindow

    private var selectedDateBinding: Binding<Date> {
        Binding(
            get: { model.selectedDate.startOfDay(timeZone: model.timeZone) },
            set: { model.selectDate($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("관찰 타임라인").font(.largeTitle.bold())
                    Text("하루의 활동과 관찰하지 못한 시간을 살펴봅니다.").foregroundStyle(.secondary)
                }
                Spacer()
                if let signOut {
                    Button("라벨 검토") { openWindow(id: "label-review") }
                    Button("로그아웃", action: signOut)
                }
            }

            if showsPreviewNotice {
                Label("타임라인 UI 미리보기의 예시 데이터입니다.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                Button { model.moveDate(by: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("이전 날짜")
                DatePicker("날짜", selection: selectedDateBinding, displayedComponents: .date)
                    .labelsHidden().accessibilityLabel("관찰 날짜")
                    .environment(\.timeZone, model.timeZone)
                Button { model.moveDate(by: 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("다음 날짜")
                Button("오늘") { model.selectDate(TimelineDate(.now, timeZone: model.timeZone)) }
                Button("새로고침") { model.refresh() }
                    .disabled(model.loadState == .loading)
                    .accessibilityIdentifier("timeline-refresh")
                Text("\(model.timeZone.identifier) 기준")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Picker("보기", selection: Binding(get: { model.style }, set: model.selectStyle)) {
                    ForEach(TimelineStyle.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented).frame(width: 180).accessibilityIdentifier("timeline-style")
            }

            Divider()

            switch model.loadState {
            case .loading:
                ProgressView(model.isRefreshing ? "새로고침 중…" : "타임라인을 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    selectedDateHeading
                    ContentUnavailableView("기록을 불러오지 못했습니다", systemImage: "exclamationmark.arrow.triangle.2.circlepath", description: Text(message))
                    Button("다시 시도") { model.refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .empty:
                VStack(alignment: .leading, spacing: 12) {
                    selectedDateHeading
                    ContentUnavailableView("이 날짜에 기록이 없습니다", systemImage: "calendar.badge.exclamationmark", description: Text("다른 날짜를 선택해 보세요."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loaded:
                HStack {
                    Text(model.selectedDate.description).font(.title3.bold()).accessibilityIdentifier("timeline-selected-date")
                    Spacer()
                    Text("\(model.presentations.count)개 표시 구간")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    switch model.style {
                    case .list:
                        TimelineList(entries: model.presentations, timeZone: model.timeZone)
                    case .timeAxis:
                        TimelineTimeAxis(
                            entries: model.presentations,
                            day: model.day!,
                            selectedSegmentID: model.selectedSegmentID,
                            onSelect: model.selectSegment
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
    }

    private var selectedDateHeading: some View {
        Text(model.selectedDate.description)
            .font(.title3.bold())
            .accessibilityIdentifier("timeline-selected-date")
    }
}

private struct TimelineList: View {
    let entries: [TimelinePresentation]
    let timeZone: TimeZone

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 14) {
                        Text(entry.timeText(timeZone: timeZone))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 115, alignment: .leading)
                        Image(systemName: entry.kind.symbol).foregroundStyle(color(for: entry.kind)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(entry.title).font(.headline)
                                TimelineBadge(entry: entry)
                                Spacer()
                                Text(entry.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if !entry.context.isEmpty { Text(entry.context).font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(entry.kind == .gap ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .overlay(alignment: .bottom) { Divider() }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("timeline-list")
    }
}

private struct TimelineBadge: View {
    let entry: TimelinePresentation

    var body: some View {
        HStack(spacing: 5) {
            Text(entry.kind.label)
            if entry.isZeroLength { Text("0초") }
            if entry.isOpen { Text("열린 구간") }
        }
        .font(.caption2.bold()).foregroundStyle(color(for: entry.kind))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(color(for: entry.kind).opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct TimelineTimeAxis: View {
    let entries: [TimelinePresentation]
    let day: TimelineDay
    let selectedSegmentID: UUID?
    let onSelect: (UUID?) -> Void

    private let pointsPerMinute: CGFloat = 1.25
    private var timeZone: TimeZone { TimeZone(identifier: day.timeZoneID) ?? .current }
    private var dayStart: Date { day.date.startOfDay(timeZone: timeZone) }
    private var dayEnd: Date { day.date.adding(days: 1, timeZone: timeZone).startOfDay(timeZone: timeZone) }
    private var visibleStart: Date {
        guard let earliest = entries.map(\.start).min() else { return dayStart }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return max(dayStart, calendar.dateInterval(of: .hour, for: earliest)?.start ?? earliest)
    }
    private var visibleEnd: Date {
        let latest = entries.map { $0.displayEnd ?? $0.start }.max() ?? dayStart
        let isToday = TimelineDate(.now, timeZone: timeZone) == day.date
        let current = isToday ? min(.now, dayEnd) : dayEnd
        let extent = max(latest, current)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let roundedEnd = calendar.dateInterval(of: .hour, for: extent)?.end ?? extent
        return min(dayEnd, max(visibleStart.addingTimeInterval(3600), roundedEnd))
    }
    private var totalMinutes: Int { max(60, Int(visibleEnd.timeIntervalSince(visibleStart) / 60)) }
    private var height: CGFloat { CGFloat(totalMinutes) * pointsPerMinute }
    private var selectedEntry: TimelinePresentation? { entries.first { $0.id == selectedSegmentID } ?? entries.first }
    private var hourTicks: [Int] { Array(stride(from: 0, through: totalMinutes / 60, by: 1)) }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        ForEach(hourTicks, id: \.self) { hour in
                            Text(hourLabel(hour))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                .offset(y: max(0, CGFloat(hour * 60) * pointsPerMinute - 6))
                        }
                    }
                    .frame(width: 44, height: height, alignment: .top)

                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            ForEach(hourTicks, id: \.self) { hour in
                                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                                    .offset(y: CGFloat(hour * 60) * pointsPerMinute)
                            }
                            ForEach(entries) { entry in
                                let top = position(of: entry.start)
                                if entry.isZeroLength || entry.displayEnd == nil {
                                    Button { onSelect(entry.id) } label: {
                                        Label(entry.title + (entry.isZeroLength ? " · 0초 관찰" : " · 종료 시각 없음"), systemImage: entry.kind.symbol)
                                            .font(.caption2).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(color(for: entry.kind).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain).offset(x: max(0, geometry.size.width - 205), y: top - 12).zIndex(2)
                                } else {
                                    let blockHeight = max(5, position(of: entry.displayEnd!) - top)
                                    Button { onSelect(entry.id) } label: {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("\(entry.timeText(timeZone: timeZone)) · \(entry.title)").font(.caption.bold()).lineLimit(1)
                                            if blockHeight > 42 && !entry.context.isEmpty { Text(entry.context).font(.caption2).lineLimit(1) }
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(color(for: entry.kind).opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(color(for: entry.kind).opacity(0.35)))
                                    }
                                    .buttonStyle(.plain).frame(width: geometry.size.width - 12, height: blockHeight)
                                    .offset(x: 6, y: top)
                                }
                            }
                        }
                    }
                    .frame(height: height)
                }
            }
            .accessibilityIdentifier("timeline-time-axis")

            if let selectedEntry {
                VStack(alignment: .leading, spacing: 12) {
                    Text(selectedEntry.title).font(.headline)
                    TimelineBadge(entry: selectedEntry)
                    if !selectedEntry.context.isEmpty { Text(selectedEntry.context).font(.callout).foregroundStyle(.secondary) }
                    Divider()
                    LabeledContent("시각", value: selectedEntry.timeText(timeZone: timeZone))
                    LabeledContent("길이", value: selectedEntry.durationText)
                    Spacer()
                }
                .padding(16).frame(width: 220).frame(maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func position(of date: Date) -> CGFloat {
        CGFloat(max(0, min(visibleEnd.timeIntervalSince(visibleStart), date.timeIntervalSince(visibleStart))) / 60) * pointsPerMinute
    }

    private func hourLabel(_ offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(byAdding: .hour, value: offset, to: visibleStart) ?? visibleStart
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private func color(for kind: TimelinePresentationKind) -> Color {
    switch kind {
    case .detail: .blue
    case .opaque: .purple
    case .gap: .secondary
    }
}
