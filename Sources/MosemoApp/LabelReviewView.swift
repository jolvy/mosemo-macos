import SwiftUI
import MosemoAPI

struct LabelReviewView: View {
    @ObservedObject var viewModel: LabelReviewViewModel

    private var selectedDateBinding: Binding<Date> {
        Binding(
            get: { viewModel.selectedDate.startOfDay(timeZone: viewModel.timeZone) },
            set: { viewModel.selectDate($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            LabelReviewHeader(segmentCount: viewModel.segmentCount)

            HStack(spacing: 10) {
                Button { viewModel.moveDate(by: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("이전 날짜")
                DatePicker("검토 날짜", selection: selectedDateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("검토 날짜")
                    .environment(\.timeZone, viewModel.timeZone)
                Button { viewModel.moveDate(by: 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("다음 날짜")
                Button("오늘") {
                    viewModel.selectDate(TimelineDate(.now, timeZone: viewModel.timeZone))
                }
                Text("\(viewModel.timeZone.identifier) 기준")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("새로고침", systemImage: "arrow.clockwise") {
                    Task { await viewModel.load() }
                }
            }

            Label("이 화면의 완료 처리는 임시 표시입니다. 서버에 저장되지 않으며 새로고침하면 서버 상태로 돌아옵니다.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView("라벨 제안을 불러오는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 12) {
                    ContentUnavailableView("제안을 불러오지 못했습니다", systemImage: "wifi.exclamationmark", description: Text(message))
                    Button("다시 시도") { Task { await viewModel.load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if viewModel.groups.isEmpty {
                    ContentUnavailableView(
                        "검토할 제안이 없습니다",
                        systemImage: "checkmark.circle",
                        description: Text("새 활동의 제안이 준비되면 여기에 표시됩니다.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LabelReviewSelectionSummary(
                        selectedGroupCount: viewModel.selectedGroups.count,
                        selectedSegmentCount: viewModel.selectedSegmentCount,
                        missingChoiceCount: viewModel.missingChoiceCount,
                        onConfirm: viewModel.confirmSelectedGroups
                    )
                    LabelReviewTable(viewModel: viewModel)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await viewModel.load() }
    }
}

private struct LabelReviewHeader: View {
    let segmentCount: Int

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("라벨 제안")
                    .font(.largeTitle.bold())
                Text("검토 대기 중인 활동 \(segmentCount)건 · 이어진 기록은 한 묶음으로 표시됩니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("검토 대기", systemImage: "tray.full")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct LabelReviewSelectionSummary: View {
    let selectedGroupCount: Int
    let selectedSegmentCount: Int
    let missingChoiceCount: Int
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(selectedGroupCount)개 묶음 선택 · \(selectedSegmentCount)개 기록")
                    .font(.subheadline.weight(.semibold))
                Text(missingChoiceCount == 0
                     ? "각 기록의 현재 선택으로 로컬 완료 처리합니다."
                     : "라벨 선택이 필요한 기록 \(missingChoiceCount)건을 먼저 지정하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("선택한 묶음 로컬 완료", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .disabled(selectedGroupCount == 0 || missingChoiceCount > 0)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LabelReviewTable: View {
    @ObservedObject var viewModel: LabelReviewViewModel

    var body: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header
                    ForEach(viewModel.groups) { group in
                        LabelReviewGroupRow(
                            group: group,
                            timeZone: viewModel.timeZone,
                            labels: viewModel.labels,
                            isSelected: viewModel.selectedGroupIDs.contains(group.id),
                            isExpanded: viewModel.expandedGroupIDs.contains(group.id),
                            selectionSummary: viewModel.selectionSummary(for: group.segments),
                            actionTitle: viewModel.groupActionTitle(group),
                            canConfirm: viewModel.canConfirm(group.segments),
                            onToggleSelection: { viewModel.toggleSelection(for: group) },
                            onToggleExpansion: { viewModel.toggleExpansion(for: group) },
                            onConfirm: { viewModel.confirm(group) }
                        )
                        if viewModel.expandedGroupIDs.contains(group.id) {
                            ForEach(group.segments) { segment in
                                LabelReviewSegmentRow(
                                    segment: segment,
                                    timeZone: viewModel.timeZone,
                                    labels: viewModel.labels,
                                    selectionTitle: viewModel.title(for: viewModel.selection(for: segment)),
                                    canConfirm: viewModel.canConfirm([segment]),
                                    onSelect: { viewModel.setSelection($0, for: segment) },
                                    onConfirm: { viewModel.confirm(segment) }
                                )
                            }
                        }
                    }
                }
                .frame(minWidth: 900)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: viewModel.toggleAllGroups) {
                Image(systemName: viewModel.allGroupsSelected
                      ? "checkmark.square.fill"
                      : viewModel.selectedGroups.isEmpty ? "square" : "minus.square.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(viewModel.allGroupsSelected ? "전체 선택 해제" : "모든 묶음 선택")
            .frame(width: 36)
            columnHeader("시간", width: 110)
            columnHeader("묶음 / 기록", width: 215)
            columnHeader("AI 제안", width: 150)
            columnHeader("현재 선택", width: 160)
            columnHeader("작업", width: 225)
        }
        .padding(.vertical, 12)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func columnHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }
}

private struct LabelReviewGroupRow: View {
    let group: LabelReviewGroup
    let timeZone: TimeZone
    let labels: [LabelReviewLabel]
    let isSelected: Bool
    let isExpanded: Bool
    let selectionSummary: String
    let actionTitle: String
    let canConfirm: Bool
    let onToggleSelection: () -> Void
    let onToggleExpansion: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("\(timeRange) 묶음 선택")
            .frame(width: 36)

            Text(timeRange)
                .font(.subheadline.monospacedDigit())
                .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.proposal.selection?.title(in: labels) ?? "라벨 선택 필요")
                    .font(.subheadline.weight(.semibold))
                Text("\(group.segments.count)개 기록 · \(group.durationMinutes)분")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 215, alignment: .leading)

            LabelReviewProposalBadge(proposal: group.proposal, labels: labels)
                .frame(width: 150, alignment: .leading)

            Text(selectionSummary)
                .font(.caption)
                .frame(width: 160, alignment: .leading)

            HStack(spacing: 7) {
                Button(actionTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
                Button(action: onToggleExpansion) {
                    Label("펼치기", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(group.segments.count)개 기록 \(isExpanded ? "접기" : "펼치기")")
            }
            .controlSize(.small)
            .frame(width: 225, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var timeRange: String {
        "\(group.first.startedAt.reviewTime(in: timeZone))–\(group.last.endedAt.reviewTime(in: timeZone))"
    }
}

private struct LabelReviewSegmentRow: View {
    let segment: LabelReviewSegment
    let timeZone: TimeZone
    let labels: [LabelReviewLabel]
    let selectionTitle: String
    let canConfirm: Bool
    let onSelect: (LabelReviewSelection) -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 36)
            Text("\(segment.startedAt.reviewTime(in: timeZone))–\(segment.endedAt.reviewTime(in: timeZone))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(segment.title).font(.subheadline.weight(.medium))
                Text("\(segment.appName) · \(segment.durationMinutes)분")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 215, alignment: .leading)

            LabelReviewProposalBadge(proposal: segment.proposal, labels: labels)
                .frame(width: 150, alignment: .leading)

            LabelReviewChoiceMenu(
                labels: labels,
                selectionTitle: selectionTitle,
                onSelect: onSelect
            )
            .frame(width: 160, alignment: .leading)

            Button("이 기록 로컬 완료", action: onConfirm)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canConfirm)
                .frame(width: 225, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct LabelReviewChoiceMenu: View {
    let labels: [LabelReviewLabel]
    let selectionTitle: String
    let onSelect: (LabelReviewSelection) -> Void

    var body: some View {
        Menu {
            ForEach(labels.filter { $0.archivedAt == nil }) { label in
                Button(label.displayName) { onSelect(.label(id: label.id)) }
            }
            Button("미분류") { onSelect(.unclassified) }
        } label: {
            Text(selectionTitle)
                .frame(maxWidth: 125, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .padding(.leading, 10)
        .frame(width: 145, height: 29, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.65), lineWidth: 1)
        }
        .accessibilityLabel("라벨 선택: \(selectionTitle)")
    }
}

private struct LabelReviewProposalBadge: View {
    let proposal: LabelReviewProposal
    let labels: [LabelReviewLabel]

    var body: some View {
        Text(proposal.title(in: labels))
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var color: Color {
        switch proposal {
        case .ready: .blue
        case .waiting, .processing: .orange
        case .failed: .red
        }
    }
}

private extension Date {
    func reviewTime(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self)
    }
}

#if DEBUG
struct LabelReviewDemoView: View {
    @StateObject private var viewModel = LabelReviewViewModel(fetcher: MockLabelReviewFetcher.demo)

    var body: some View {
        LabelReviewView(viewModel: viewModel)
            .overlay(alignment: .bottomTrailing) {
                Text("DEBUG · 모의 API 응답")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
    }
}
#endif

struct LabelReviewScreen: View {
    @StateObject private var viewModel: LabelReviewViewModel

    init(fetcher: any LabelReviewFetching, timeZone: TimeZone) {
        _viewModel = StateObject(wrappedValue: LabelReviewViewModel(
            fetcher: fetcher,
            timeZone: timeZone
        ))
    }

    var body: some View {
        LabelReviewView(viewModel: viewModel)
    }
}
