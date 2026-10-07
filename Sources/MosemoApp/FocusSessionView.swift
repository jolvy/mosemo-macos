import SwiftUI

struct FocusSessionView: View {
    @ObservedObject var model: FocusSessionViewModel

    private var reviewing: Bool { model.phase == .review }
    private var phaseTitle: String {
        switch model.phase {
        case .ready: "준비"
        case .running: "진행 중"
        case .paused: "일시중지"
        case .review: "다음 세션 준비"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("집중 세션").font(.largeTitle.bold())
                    Text("하나의 작업에 집중하고, 마친 뒤 기록을 확인하세요.")
                        .foregroundStyle(.secondary)
                }
                Label(model.persistsSessions ? "완료한 세션은 저장되며, 아래에서 날짜별로 확인할 수 있습니다." : "미리보기 · 세션은 서버에 저장되지 않습니다.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    timerPane.frame(maxWidth: .infinity, minHeight: 360)
                    Divider()
                    inputPane.frame(width: 260)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                if model.isSaving { ProgressView("서버에 저장하는 중…").controlSize(.small) }
                if let error = model.persistenceError { Text(error).font(.caption).foregroundStyle(.red) }
                if model.persistsSessions { historyPane }
            }
            .padding(24)
        }
        .environment(\.timeZone, model.displayTimeZone)
        .task { await model.loadLabels() }
        .task(id: model.historyDate) { await model.loadHistory() }
    }

    private var timerPane: some View {
        VStack(spacing: 18) {
            Text(phaseTitle)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.mint.opacity(0.12), in: Capsule())
            if model.phase == .ready {
                TextField("00:00:00", text: $model.timeInput)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 62, weight: .light, design: .monospaced))
                    .accessibilityLabel("시작 시간 (시:분:초)")
                    .accessibilityIdentifier("focus-time")
                    .disabled(!model.canEditInputs)
                Text(FocusSessionViewModel.parseTime(model.timeInput) != nil
                     ? "00:00:00부터 시작하거나, 시간을 정해 거꾸로 셉니다."
                     : "시:분:초 형식으로 입력하세요. 예: 00:20:00")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(FocusSessionViewModel.format(model.displaySeconds))
                    .font(.system(size: 62, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .accessibilityIdentifier("focus-clock")
                Text(reviewing ? "오른쪽 기록을 완료하면 다음 작업을 시작할 수 있어요."
                     : model.targetSeconds > 0 ? "남은 시간" : "작업 시간 · 일시중지 시간 제외")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                switch model.phase {
                case .ready:
                    Button("시작") { Task { await model.startPersisted() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canStart)
                        .accessibilityIdentifier("focus-start")
                    Button("초기화", action: model.reset).disabled(model.isSaving).accessibilityIdentifier("focus-reset")
                case .running:
                    Button("일시중지", action: model.pause).accessibilityIdentifier("focus-pause")
                    Button("종료", action: model.end).accessibilityIdentifier("focus-end")
                case .paused:
                    Button("재개", action: model.resume).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("focus-resume")
                    Button("종료", action: model.end).accessibilityIdentifier("focus-end")
                case .review:
                    Button("시작") {}.disabled(true)
                }
            }
            .controlSize(.large)
        }
        .padding(.top, 35)
    }

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(reviewing ? "작업 기록 확인" : "작업 정보").font(.headline)
            Group {
                if reviewing {
                    Text("실제 작업 시간 · \(FocusSessionViewModel.format(model.workSeconds))")
                } else if let completed = model.lastCompleted {
                    Text("\(FocusSessionViewModel.format(completed.seconds)) · \(completed.label.displayName) 세션을 완료했어요.")
                } else {
                    Text("라벨과 설명은 작업을 마친 뒤에도 수정할 수 있어요.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).frame(height: 40, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                Text(reviewing ? "라벨 · 필수" : "라벨 · 선택").font(.caption.weight(.semibold))
                Picker("라벨", selection: $model.selectedLabelID) {
                    Text("라벨을 선택하세요").tag(UUID?.none)
                    ForEach(model.labels, id: \.id) { label in
                        Text(label.displayName).tag(Optional(label.id))
                    }
                }
                .labelsHidden().accessibilityIdentifier("focus-label")
                .disabled(!model.canEditInputs || (model.isLoadingLabels && model.labels.isEmpty))
                if model.isLoadingLabels {
                    ProgressView("라벨을 불러오는 중…").controlSize(.small)
                } else if let error = model.labelError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("다시 시도") { Task { await model.loadLabels() } }
                } else if model.labels.isEmpty {
                    Text("선택할 수 있는 활성 라벨이 없습니다.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(reviewing ? "라벨을 선택하면 세션을 완료할 수 있어요." : "마친 뒤 선택해도 괜찮아요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("설명 · 선택").font(.caption.weight(.semibold))
                TextEditor(text: $model.description)
                    .font(.body)
                    .padding(6)
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("설명")
                    .accessibilityIdentifier("focus-description")
                    .disabled(!model.canEditInputs)
            }
            if reviewing {
                HStack {
                    Spacer()
                    Button("완료") { Task { await model.completePersisted() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canComplete)
                        .accessibilityIdentifier("focus-complete")
                }
            }
        }
        .padding(.top, 18)
    }
    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack {
                Text("완료한 집중 세션").font(.headline)
                Spacer()
                DatePicker("날짜", selection: $model.historyDate, in: ...Date.now, displayedComponents: .date)
                    .labelsHidden().accessibilityIdentifier("focus-history-date")
                Button("새로고침") { Task { await model.loadHistory() } }.disabled(model.isLoadingHistory)
            }
            if model.isLoadingHistory { ProgressView().controlSize(.small) }
            if let error = model.historyError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if model.history.isEmpty && !model.isLoadingHistory && model.historyError == nil {
                Text("이 날짜에 완료한 세션이 없습니다.").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(model.history) { record in
                DisclosureGroup {
                    Text(record.description.isEmpty ? "작성한 설명이 없습니다." : record.description)
                        .foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 8)
                } label: {
                    HStack {
                        Text(record.startedAt, style: .time).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(model.labelName(for: record.labelID))
                        Spacer()
                        Text(FocusSessionViewModel.format(TimeInterval(record.workSeconds ?? 0))).monospacedDigit()
                    }.padding(.vertical, 8)
                }
                Divider()
            }
        }
    }

}
