import AppKit
import SwiftUI

struct ActivityChatView: View {
    @ObservedObject var model: ActivityChatViewModel
    private let questions = ["오늘 어떤 일을 했어?", "가장 오래 사용한 앱은?", "오전 활동을 요약해줘"]
    @State private var copiedMessageID: UUID?
    private let chatContentWidth: CGFloat = 760
    private let chatHorizontalInset: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if model.selectedActivity == nil || geometry.size.width >= 760 {
                        conversationList
                        Divider()
                    }
                    chat
                    if let activity = model.selectedActivity {
                        Divider()
                        activityDetail(activity)
                            .frame(width: min(260, max(200, geometry.size.width * 0.38)))
                    }
                }
            }
        }
    }

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("대화 목록").font(.headline)
                Spacer()
                Button(action: model.newConversation) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("새 대화")
                .help("새 대화")
                .accessibilityIdentifier("chat-new-conversation")
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.conversations) { conversation in
                        Button { model.selectConversation(conversation.id) } label: {
                            Text(conversation.title)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(model.selectedConversationID == conversation.id ? Color.mint.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat-conversation-\(conversation.id)")
                    }
                }
                .padding(.horizontal, 14.5)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 190)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        if model.conversation.messages.isEmpty { welcome }
                        ForEach(model.conversation.messages) { message in
                            messageView(message).id(message.id)
                        }
                        if model.conversation.isGenerating {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("예시 활동을 살펴보고 답변을 생성 중입니다…")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .frame(maxWidth: chatContentWidth, alignment: .leading)
                    .padding(.horizontal, chatHorizontalInset)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.conversation.messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: model.conversation.isGenerating) { _, generating in
                    if generating { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: model.selectedConversationID) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            Divider()
            composer
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.mint)
            Text("오늘의 활동, 함께 돌아볼까요?").font(.title2.bold())
            Text("무슨 일을 했는지 묻고, 답변의 근거가 된 활동을 확인해 보세요.")
                .foregroundStyle(.secondary)
            ForEach(questions, id: \.self) { question in
                Button(question) { model.send(question) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 40)
    }

    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.isUser ? "나" : "Mosemo · 예시 답변")
                .font(.caption.weight(.semibold)).foregroundStyle(.mint)
            Text(message.text)
                .textSelection(.enabled)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if !message.references.isEmpty {
                ViewThatFits(in: .horizontal) {
                    references(message, columns: 2)
                    references(message, columns: 1)
                }
            }
            if !message.isUser, !message.isStopped {
                Button(copiedMessageID == message.id ? "복사됨" : "답변 복사", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(message.text, forType: .string) { copiedMessageID = message.id }
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(message.isUser ? 16 : 0)
        .background(message.isUser ? Color.mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .padding(.leading, message.isUser ? 30 : 0)
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private func references(_ message: ChatMessage, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading) {
            ForEach(message.references) { activity in
                Button { model.selectedActivity = activity } label: {
                    Label("\(activity.time) · \(activity.app)", systemImage: "sidebar.right")
                        .font(.caption).multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered).tint(.mint)
                .accessibilityIdentifier("chat-reference-\(activity.id)")
            }
        }
    }

    private var composer: some View {
        let conversationID = model.selectedConversationID
        return VStack(spacing: 8) {
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("활동에 대해 물어보세요…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 6)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    ActivityChatInput(
                        text: Binding(
                            get: { model.draft(for: conversationID) },
                            set: { model.updateDraft($0, for: conversationID) }
                        ),
                        conversationID: conversationID,
                        onSend: { model.send() }
                    )
                }
                HStack {
                    Spacer()
                    if model.conversation.isGenerating {
                        Button("중단", systemImage: "stop.fill", action: model.stop)
                            .accessibilityIdentifier("chat-stop")
                    } else {
                        Button("보내기", systemImage: "arrow.up") { model.send() }
                            .buttonStyle(.borderedProminent).tint(.mint)
                            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("chat-send")
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.4)))
            Text("Enter 전송 · Shift+Enter 줄바꿈 · 예시 활동 기반 답변")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: chatContentWidth)
        .padding(.horizontal, chatHorizontalInset)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private func activityDetail(_ activity: ChatActivity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("참고 활동").font(.headline)
                    Spacer()
                    Button { model.selectedActivity = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("상세 패널 닫기")
                        .accessibilityIdentifier("chat-close-detail")
                }
                detailRow("날짜", "2026. 10. 5. · Asia/Seoul")
                detailRow("시간", "\(activity.time) (\(activity.minutes)분)")
                detailRow("앱", activity.app)
                detailRow("활동 제목", activity.title)
                Text("프로토타입 예시 데이터").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("chat-activity-detail")
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
