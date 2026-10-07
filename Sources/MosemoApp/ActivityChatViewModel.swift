import Foundation
import Combine

struct ChatActivity: Identifiable, Equatable {
    let id: String
    let time: String
    let app: String
    let title: String
    let minutes: Int

    static let samples: [ChatActivity] = [
        .init(id: "a1", time: "09:00–10:00", app: "Xcode", title: "Mosemo · 타임라인 화면 개발", minutes: 60),
        .init(id: "a2", time: "10:00–10:45", app: "Google Chrome", title: "SwiftUI 공식 문서 확인", minutes: 45),
        .init(id: "a3", time: "10:45–11:00", app: "Notes", title: "활동 채팅 UI 아이디어 정리", minutes: 15),
        .init(id: "a4", time: "11:00–11:35", app: "Xcode", title: "Mosemo · 라벨 검토 화면 개발", minutes: 35),
        .init(id: "a5", time: "11:35–11:50", app: "Slack", title: "팀과 작업 내용 공유", minutes: 15),
        .init(id: "a6", time: "11:50–12:00", app: "Notes", title: "오전 작업 회고", minutes: 10),
        .init(id: "a7", time: "12:00–12:10", app: "정보 가림", title: "개인정보 보호로 내용을 확인할 수 없습니다", minutes: 10),
        .init(id: "a8", time: "12:10–12:30", app: "수집 공백", title: "관찰된 활동이 없습니다", minutes: 20),
    ]
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
    var references: [ChatActivity] = []
    var isStopped = false
}

struct ChatConversation: Identifiable {
    let id = UUID()
    var title = "새 대화"
    var messages: [ChatMessage] = []
    var draft = ""
    var isGenerating = false
}

/// UI-only demo. No network requests or persistent conversation storage.
@MainActor
final class ActivityChatViewModel: ObservableObject {
    @Published private(set) var conversations: [ChatConversation]
    @Published private(set) var selectedConversationID: UUID
    @Published var selectedActivity: ChatActivity?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let responseDelay: Duration

    init(responseDelay: Duration = .milliseconds(1800)) {
        let conversation = ChatConversation()
        conversations = [conversation]
        selectedConversationID = conversation.id
        self.responseDelay = responseDelay
    }

    deinit { tasks.values.forEach { $0.cancel() } }

    var conversation: ChatConversation {
        conversations.first { $0.id == selectedConversationID }!
    }

    var draft: String {
        get { draft(for: selectedConversationID) }
        set { updateDraft(newValue, for: selectedConversationID) }
    }

    func draft(for conversationID: UUID) -> String {
        conversations.first { $0.id == conversationID }?.draft ?? ""
    }

    func updateDraft(_ text: String, for conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].draft = text
    }

    func newConversation() {
        if let conversation = conversations.first(where: { $0.messages.isEmpty }) {
            selectConversation(conversation.id)
            return
        }
        let conversation = ChatConversation()
        conversations.insert(conversation, at: 0)
        selectConversation(conversation.id)
    }

    func selectConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedConversationID = id
        selectedActivity = nil
    }

    func send(_ question: String? = nil) {
        let text = (question ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !conversation.isGenerating,
              let index = conversations.firstIndex(where: { $0.id == selectedConversationID }) else { return }
        let id = selectedConversationID
        conversations[index].messages.append(.init(isUser: true, text: text))
        if conversations[index].messages.count == 1 {
            conversations[index].title = String(text.prefix(24)) + (text.count > 24 ? "…" : "")
        }
        conversations[index].draft = ""
        conversations[index].isGenerating = true
        let delay = responseDelay
        tasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self,
                  let index = self.conversations.firstIndex(where: { $0.id == id }) else { return }
            self.conversations[index].messages.append(Self.sampleAnswer(to: text))
            self.conversations[index].isGenerating = false
            self.tasks[id] = nil
        }
    }

    func stop() {
        guard conversation.isGenerating,
              let index = conversations.firstIndex(where: { $0.id == selectedConversationID }) else { return }
        tasks.removeValue(forKey: selectedConversationID)?.cancel()
        conversations[index].isGenerating = false
        conversations[index].messages.append(.init(
            isUser: false, text: "답변 생성을 중단했어요. 질문을 다시 보내거나 새 질문을 이어갈 수 있어요.", isStopped: true
        ))
    }

    private static func sampleAnswer(to question: String) -> ChatMessage {
        if question.contains("오래") || question.contains("많이") {
            return .init(isUser: false, text: """
            확인 가능한 예시 활동에서 가장 오래 사용한 앱은 Xcode예요.

            • Xcode: 95분 (타임라인 개발 60분 + 라벨 검토 개발 35분)
            • Google Chrome: 45분
            • Notes: 25분
            • Slack: 15분

            정보가 가려진 10분과 수집 공백 20분은 앱별 집계에 포함하지 않았어요.
            """, references: Array(ChatActivity.samples.prefix(6)))
        }
        if question.contains("오전") {
            let lines = ChatActivity.samples.prefix(6).map { "\($0.time) · \($0.app) · \($0.title)" }.joined(separator: "\n")
            return .init(isUser: false, text: "오전에는 Mosemo 개발과 문서 확인에 시간을 썼어요.\n\n\(lines)\n\n확인 가능한 오전 활동은 총 180분이에요. 창 제목을 바탕으로 한 예시 요약이므로 실제 작업 성과까지 알 수는 없어요.", references: Array(ChatActivity.samples.prefix(6)))
        }
        let prefix = ["오늘", "어떤", "요약"].contains { question.contains($0) }
            ? "오늘 기록된 예시 활동을 정리했어요."
            : "실제 AI가 연결되지 않아 질문에 맞춘 답변 대신 예시 활동 요약을 보여드릴게요."
        return .init(isUser: false, text: """
        \(prefix)

        주로 Mosemo 화면을 개발하고 SwiftUI 문서를 확인했어요. Xcode에서 개발에 95분, Chrome에서 문서 확인에 45분을 사용했어요. Notes에는 UI 아이디어와 회고를 25분 동안 정리했고, Slack으로 작업 내용을 15분 동안 공유했어요.

        12:00–12:10은 정보가 가려져 내용을 알 수 없고, 12:10–12:30은 수집 공백이에요. 이 시간에 어떤 일을 했는지는 추정하지 않았어요.
        """, references: ChatActivity.samples)
    }
}
