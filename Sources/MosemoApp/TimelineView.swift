import SwiftUI
import MosemoAPI

struct TimelineView: View {
    @ObservedObject var model: TimelineViewModel
    let showsPreviewNotice: Bool
    var previewUpload: (() -> Void)? = nil

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
                    .overlay(alignment: .trailing) {
                        if let previewUpload {
                            Button("새 기록 시뮬레이션", action: previewUpload)
                                .accessibilityIdentifier("timeline-preview-upload")
                                .padding(.trailing, 10)
                        }
                    }
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
                Text("\(model.timeZone.identifier) 기준")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Picker("보기", selection: Binding(get: { model.style }, set: model.selectStyle)) {
                    ForEach(TimelineStyle.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented).frame(width: 180).accessibilityIdentifier("timeline-style")
            }

            Divider()

            if let message = model.refreshError {
                HStack(spacing: 8) {
                    Label("최신 기록을 반영하지 못했습니다. \(message)", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("다시 시도") { model.refresh() }
                }
                .font(.callout)
                .padding(9)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.removedSelectionNotice {
                Label("기록 구성이 변경되어 선택한 구간이 사라졌습니다.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            switch model.loadState {
            case .loading:
                ProgressView("타임라인을 불러오는 중…")
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
                HStack(alignment: .top, spacing: 20) {
                    switch model.style {
                    case .list:
                        TimelineList(model: model)
                    case .timeAxis:
                        TimelineTimeAxis(model: model).id(model.axisKey)
                    }
                    if let entry = model.presentations.first(where: { $0.id == model.selectedSegmentID }) {
                        TimelineDetail(entry: entry, timeZone: model.timeZone)
                    } else if model.presentations.isEmpty {
                        Text("이 날짜에 기록이 없습니다").foregroundStyle(.secondary).frame(width: 220)
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
    @State private var isAtBottom = false
    @State private var shouldFollowNewItems = false
    @State private var previousEntryIDs: Set<UUID> = []
    @State private var scrollToBottomRequest = 0
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
                        .contentShape(Rectangle())
                        .background(model.selectedSegmentID == entry.id ? Color.accentColor.opacity(0.12) :
                                    entry.kind == .gap ? Color(nsColor: .controlBackgroundColor) : .clear)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("timeline-segment-\(entry.id)")
                }
            }
        }
        .background(TimelineListScrollObserver(scrollToBottomRequest: scrollToBottomRequest) { atBottom in
            isAtBottom = atBottom
            if model.isRefreshing { shouldFollowNewItems = atBottom }
        })
        .onAppear { previousEntryIDs = Set(entries.map(\.id)) }
        .onChange(of: model.isRefreshing) { _, isRefreshing in
            if isRefreshing { shouldFollowNewItems = isAtBottom }
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            let currentIDs = Set(ids)
            let addedItems = !currentIDs.subtracting(previousEntryIDs).isEmpty
            previousEntryIDs = currentIDs
            guard addedItems, shouldFollowNewItems else { return }
            shouldFollowNewItems = false
            scrollToBottomRequest += 1
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
    private var timeZone: TimeZone { model.timeZone }
    private var height: CGFloat { axis.height }
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


        }
    }

}

private struct TimelineDetail: View {
    let entry: TimelinePresentation
    let timeZone: TimeZone

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("총 시간").font(.caption).foregroundStyle(.secondary)
                        Text(entry.preciseDurationText).font(.title2.monospacedDigit().bold())
                            .accessibilityIdentifier("timeline-detail-duration")
                        Text(entry.detailRangeText(timeZone: timeZone))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("timeline-detail-range")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(entry.kind == .detail ? "확정 라벨" : "구간 종류")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.labelStateText ?? (entry.kind == .detail ? "미확정" : entry.kind.label))
                            .font(.callout.bold())
                            .accessibilityIdentifier("timeline-detail-confirmed-label")
                    }
                }
                Divider()
                Text("타임라인").font(.headline)
                if let details = entry.details {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text("총")
                            Text("시작시간")
                            Text("종료시간")
                            Text("종류")
                            Text("상세정보")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Divider().gridCellColumns(5)
                        GridRow {
                            Text(entry.preciseDurationText)
                            Text(entry.detailTimeText(entry.start, timeZone: timeZone))
                            Text(entry.end.map { entry.detailTimeText($0, timeZone: timeZone) } ?? "종료 시각 미상")
                            Text(details.isWeb ? "웹" : "앱")
                            VStack(alignment: .leading, spacing: 8) {
                                Text(details.appName.flatMap { $0.isEmpty ? nil : $0 } ?? "앱 이름 수집 불가")
                                    .foregroundStyle(.secondary)
                                Text("제목 · " + entry.detailTitle)
                                    .accessibilityIdentifier("timeline-detail-title")
                                if let url = entry.detailURL {
                                    Text("URL · " + url).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("timeline-detail-url")
                                }
                            }
                            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.monospacedDigit())
                    }
                    .textSelection(.enabled)
                } else {
                    Text(entry.kind == .opaque
                         ? "개인정보 보호로 앱·제목·URL을 표시하지 않습니다."
                         : "이 구간에는 관찰된 항목이 없습니다. 수집 공백: " + entry.context)
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("timeline-detail-empty-reason")
                }
            }
            .padding(16)
            .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 360, idealWidth: 560, maxWidth: 600, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("timeline-detail")
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

private struct TimelineListScrollObserver: NSViewRepresentable {
    let scrollToBottomRequest: Int
    let onScroll: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(scrollToBottomRequest: scrollToBottomRequest, onScroll: onScroll)
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onScroll = onScroll
        view.handleScrollToBottomRequest(scrollToBottomRequest)
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopObserving() }

    final class ObserverView: NSView {
        var onScroll: (Bool) -> Void
        private var observation: NSObjectProtocol?
        private weak var scrollView: NSScrollView?
        private weak var clipView: NSClipView?
        private var lastOriginY: CGFloat?
        private var lastScrollToBottomRequest: Int

        init(scrollToBottomRequest: Int, onScroll: @escaping (Bool) -> Void) {
            lastScrollToBottomRequest = scrollToBottomRequest
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            self.scrollView = scrollView
            let clipView = scrollView.contentView
            self.clipView = clipView
            clipView.postsBoundsChangedNotifications = true
            DispatchQueue.main.async { [weak self] in self?.reportBottomState() }
            observation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in
                guard let self, let clipView = self.clipView else { return }
                let originY = clipView.bounds.origin.y
                guard self.lastOriginY.map({ abs($0 - originY) > 0.5 }) ?? true else { return }
                self.lastOriginY = originY
                self.reportBottomState()
            }
        }

        private func reportBottomState() {
            guard let clipView, let documentView = clipView.documentView else { return }
            let originY = clipView.bounds.origin.y
            lastOriginY = originY
            if let scroller = scrollView?.verticalScroller {
                onScroll(CGFloat(scroller.floatValue) + scroller.knobProportion >= 0.99)
                return
            }
            let maximumOffset = max(0, documentView.frame.height - clipView.bounds.height)
            onScroll(maximumOffset - originY <= 12)
        }

        func handleScrollToBottomRequest(_ request: Int) {
            guard request > lastScrollToBottomRequest else { return }
            lastScrollToBottomRequest = request
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView,
                      let clipView = self.clipView, let documentView = clipView.documentView else { return }
                scrollView.layoutSubtreeIfNeeded()
                documentView.layoutSubtreeIfNeeded()
                let bottom = max(0, documentView.frame.height - clipView.bounds.height)
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: bottom))
                scrollView.reflectScrolledClipView(clipView)
                self.reportBottomState()
            }
        }

        func stopObserving() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            scrollView = nil
            clipView = nil
            lastOriginY = nil
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
