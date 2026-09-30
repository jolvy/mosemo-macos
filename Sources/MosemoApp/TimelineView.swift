import SwiftUI
import MosemoAPI

struct TimelineView: View {
    @ObservedObject var model: TimelineViewModel
    let showsPreviewNotice: Bool

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
                Button("오늘") { model.selectDate(TimelineDate(model.currentDate, timeZone: model.timeZone)) }
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
            case .empty where model.style == .list:
                VStack(alignment: .leading, spacing: 12) {
                    selectedDateHeading
                    ContentUnavailableView("이 날짜에 기록이 없습니다", systemImage: "calendar.badge.exclamationmark", description: Text("다른 날짜를 선택해 보세요."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .empty, .loaded:
                HStack {
                    Text(model.selectedDate.description).font(.title3.bold()).accessibilityIdentifier("timeline-selected-date")
                    Spacer()
                    Text("\(model.presentations.count)개 표시 구간")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    switch model.style {
                    case .list:
                        HStack(alignment: .top, spacing: 20) {
                            TimelineList(model: model)
                            if let entry = model.presentations.first(where: { $0.id == model.selectedSegmentID }) {
                                TimelineDetail(entry: entry, timeZone: model.timeZone)
                            }
                        }
                    case .timeAxis:
                        TimelineTimeAxis(model: model)
                            .id(model.axisKey)

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
    @ObservedObject var model: TimelineViewModel
    private var entries: [TimelinePresentation] { model.presentations }
    private var timeZone: TimeZone { model.timeZone }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button { model.selectSegment(entry.id) } label: {
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
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("timeline-segment-\(entry.id)")
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
            if let label = entry.labelStateText {
                if entry.confirmedLabelText != nil {
                    Label(label, systemImage: "checkmark.circle.fill")
                } else {
                    Text(label)
                }
            } else {
                Text(entry.kind.label)
            }
            if entry.isZeroLength { Text("0초") }
            if entry.isOpen { Text("열린 구간") }
        }
        .font(.caption2.bold()).foregroundStyle(color(for: entry.kind))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(color(for: entry.kind).opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct TimelineTimeAxis: View {
    @ObservedObject var model: TimelineViewModel
    @State private var didRestore = false
    @State private var restorationOffset: Double?
    private var axis: TimelineAxis { model.axis }
    private var entries: [TimelinePresentation] { model.presentations }
    private var timeZone: TimeZone { model.timeZone }
    private var height: CGFloat { axis.height }
    private var selectedEntry: TimelinePresentation? {
        entries.first { $0.id == model.selectedSegmentID } ?? entries.first
    }
    private func onSelect(_ id: UUID?) { model.selectSegment(id) }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        let contentWidth = max(viewport.size.width, 54 + Double(axis.laneCount) * 186)
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(0...Int(axis.height / TimelineAxis.pointsPerMinute), id: \.self) { minute in
                                    Color.clear.frame(width: 1, height: TimelineAxis.pointsPerMinute).id(minute)
                                }
                            }
                            .accessibilityHidden(true)
                            HStack(alignment: .top, spacing: 10) {
                                ZStack(alignment: .topTrailing) {
                                    ForEach(axis.ticks) { tick in
                                        Text(tick.label).accessibilityIdentifier("timeline-tick-\(tick.id)")
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                            .offset(y: max(0, tick.position - 6))
                                    }
                                }
                                .frame(width: 44, height: height, alignment: .top)

                                GeometryReader { geometry in
                                    ZStack(alignment: .topLeading) {
                                        ForEach(axis.ticks) { tick in
                                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                                                .offset(y: tick.position)
                                        }
                                        ForEach(axis.segments) { segment in
                                            let entry = segment.entry
                                            let laneWidth = geometry.size.width / Double(axis.laneCount)
                                            Button { onSelect(entry.id) } label: {
                                                Group {
                                                    if segment.isShort {
                                                        RoundedRectangle(cornerRadius: 3)
                                                            .fill(color(for: entry.kind))
                                                            .frame(width: 29, height: segment.visualHeight)
                                                    } else {
                                                        VStack(alignment: .leading, spacing: 1) {
                                                            Text("\(entry.timeText(timeZone: timeZone)) · \(entry.axisTitle)")
                                                                .font(.caption.bold()).lineLimit(1)
                                                            if segment.height > 42 && !entry.context.isEmpty {
                                                                Text(entry.context).font(.caption2).lineLimit(1)
                                                            }
                                                        }
                                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                                        .background(color(for: entry.kind).opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                                                    }
                                                }
                                                .frame(width: segment.isShort ? 29 : laneWidth - 12,
                                                       height: segment.hitHeight, alignment: .topLeading)
                                                .contentShape(Rectangle())
                                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                                                    color(for: entry.kind).opacity(model.selectedSegmentID == entry.id ? 1 : (segment.isShort ? 0 : 0.35))))
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("\(entry.timeText(timeZone: timeZone)) · \(entry.axisTitle) · \(entry.labelStateText ?? entry.kind.label) · \(entry.durationText)")
                                            .accessibilityIdentifier("timeline-segment-\(entry.id)")
                                            .help("\(entry.timeText(timeZone: timeZone)) · \(entry.axisTitle) · \(entry.labelStateText ?? entry.kind.label) · \(entry.durationText)")
                                            .offset(x: 6 + Double(segment.lane) * laneWidth, y: segment.top)
                                        }
                                    }
                                }
                                .frame(height: height)
                            }
                        }
                        .frame(width: contentWidth, height: height + 24)
                        .background(TimelineScrollObserver { offset in
                            if let target = restorationOffset, offset > 0 || target == 0 {
                                didRestore = true
                            }
                            if didRestore { model.saveAxisOffset(offset) }
                        })
                    }
                    .accessibilityIdentifier("timeline-time-axis")
                    .task {
                        let offset = model.initialAxisOffset(viewportHeight: viewport.size.height)
                        restorationOffset = offset
                        await Task.yield()
                        proxy.scrollTo(Int((offset / TimelineAxis.pointsPerMinute).rounded()), anchor: .top)
                        if offset == 0 { didRestore = true }
                    }
                }
            }

            if entries.isEmpty {
                Text("이 날짜에 기록이 없습니다").foregroundStyle(.secondary).frame(width: 220)
            } else if let selectedEntry {
                TimelineDetail(entry: selectedEntry, timeZone: timeZone)
            }
        }
    }

}

private struct TimelineDetail: View {
    let entry: TimelinePresentation
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title).font(.headline)
            TimelineBadge(entry: entry)
            if let label = entry.labelStateText {
                LabeledContent("확정 라벨", value: label)
                    .accessibilityIdentifier("timeline-detail-confirmed-label")
            }
            if !entry.context.isEmpty { Text(entry.context).font(.callout).foregroundStyle(.secondary) }
            Divider()
            LabeledContent("시각", value: entry.timeText(timeZone: timeZone))
            LabeledContent("길이", value: entry.durationText)
            Spacer()
        }
        .padding(16).frame(width: 220).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// AppKit bounds observation supports the macOS 14 deployment target; initial
/// positioning still uses SwiftUI's ScrollViewReader.
private struct TimelineScrollObserver: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(onScroll: onScroll) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopObserving() }

    final class ObserverView: NSView {
        var onScroll: (Double) -> Void
        private var observation: NSObjectProtocol?

        init(onScroll: @escaping (Double) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, let clipView = enclosingScrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self, weak clipView] _ in
                guard let clipView else { return }
                self?.onScroll(clipView.bounds.origin.y)
            }
        }

        func stopObserving() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
        }
    }
}

private func color(for kind: TimelinePresentationKind) -> Color {
    switch kind {
    case .detail: .blue
    case .opaque: .purple
    case .gap: .secondary
    }
}
