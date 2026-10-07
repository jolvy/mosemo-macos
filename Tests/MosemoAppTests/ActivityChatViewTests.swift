import AppKit
import SwiftUI
import XCTest
@testable import MosemoApp

@MainActor
final class ActivityChatViewTests: XCTestCase {
    func testAnswerCompletesInOriginalConversationAfterSwitching() async {
        let model = ActivityChatViewModel(responseDelay: .milliseconds(20))
        let first = model.selectedConversationID
        model.draft = "가장 오래 사용한 앱은?"
        model.send()
        model.newConversation()
        model.draft = "새 대화 초안"
        await waitUntil { model.conversations.first { $0.id == first }?.isGenerating == false }
        XCTAssertTrue(model.conversation.messages.isEmpty)
        XCTAssertEqual(model.draft, "새 대화 초안")
        model.selectConversation(first)
        XCTAssertEqual(model.conversation.messages.count, 2)
        XCTAssertTrue(model.conversation.messages[1].text.contains("95분"))
        XCTAssertEqual(model.conversation.messages[1].references.count, 6)
        XCTAssertEqual(model.draft, "")
    }

    func testStoppedAnswerCannotAppendToRetry() async {
        let model = ActivityChatViewModel(responseDelay: .milliseconds(20))
        model.send("오늘 어떤 일을 했어?")
        model.stop()
        model.send("오전 활동을 요약해줘")
        await waitUntil { !model.conversation.isGenerating }
        XCTAssertEqual(model.conversation.messages.count, 4)
        XCTAssertTrue(model.conversation.messages[1].isStopped)
        XCTAssertTrue(model.conversation.messages[3].text.contains("180분"))
        XCTAssertEqual(model.conversation.messages[3].references.map(\.id), ["a1", "a2", "a3", "a4", "a5", "a6"])
    }

    func testConversationDraftAndDetailPanelHaveIndependentLifetime() {
        let model = ActivityChatViewModel()
        let first = model.selectedConversationID
        model.send("첫 질문")
        model.stop()
        model.draft = "작성 중인 질문\n두 번째 줄"
        model.selectedActivity = ChatActivity.samples[0]
        model.newConversation()
        XCTAssertNil(model.selectedActivity)
        XCTAssertEqual(model.draft, "")
        model.draft = "다른 질문"
        model.selectConversation(first)
        XCTAssertEqual(model.draft, "작성 중인 질문\n두 번째 줄")
        XCTAssertNil(model.selectedActivity)
    }

    func testRepeatedNewConversationReusesUnstartedConversation() {
        let model = ActivityChatViewModel()
        let first = model.selectedConversationID
        model.draft = "아직 보내지 않은 질문"
        model.newConversation()
        model.newConversation()
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertEqual(model.selectedConversationID, first)
        XCTAssertEqual(model.draft, "아직 보내지 않은 질문")
    }

    func testNewConversationReturnsToExistingUnstartedConversationFromStartedChat() {
        let model = ActivityChatViewModel()
        let started = model.selectedConversationID
        model.send("오늘 어떤 일을 했어?")
        model.stop()
        model.newConversation()
        let unstarted = model.selectedConversationID
        XCTAssertNotEqual(unstarted, started)
        model.draft = "이어 작성할 질문"
        model.selectConversation(started)
        model.selectedActivity = ChatActivity.samples[0]
        model.newConversation()
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertEqual(model.selectedConversationID, unstarted)
        XCTAssertEqual(model.draft, "이어 작성할 질문")
        XCTAssertNil(model.selectedActivity)
    }

    func testReturnCommitsMarkedTextAndShiftReturnInsertsNewlineBeforeSending() {
        _ = NSApplication.shared
        let editor = ActivityChatInput.ChatTextView()
        editor.isRichText = false
        var sends = 0
        editor.onSend = { sends += 1 }
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: returnEvent())
        XCTAssertEqual(sends, 0)
        editor.unmarkText()
        editor.string = "오전 활동"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: returnEvent(modifiers: .shift))
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(editor.string.contains("\n"))
        editor.keyDown(with: returnEvent())
        XCTAssertEqual(sends, 1)
    }

    func testSwitchingConversationCommitsMarkedTextToOriginalDraft() async {
        _ = NSApplication.shared
        let model = ActivityChatViewModel()
        let first = model.selectedConversationID
        model.send("첫 질문")
        model.stop()
        model.draft = "원래 초안 "
        model.newConversation()
        let second = model.selectedConversationID
        model.draft = "다른 대화 초안"
        model.selectConversation(first)

        let host = NSHostingView(rootView: ActivityChatView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        func findEditor(_ view: NSView) -> ActivityChatInput.ChatTextView? {
            if let editor = view as? ActivityChatInput.ChatTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor($0) }.first
        }
        guard let editor = findEditor(host) else { return XCTFail("Native input was not mounted") }
        window.makeFirstResponder(editor)
        await waitUntil { editor.string == "원래 초안 " }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.didChangeText()
        XCTAssertTrue(editor.hasMarkedText())
        let composedDraft = editor.string

        model.selectConversation(second)
        await waitUntil { editor.string == "다른 대화 초안" }
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(model.draft, "다른 대화 초안")
        XCTAssertEqual(model.draft(for: first), composedDraft)
        editor.insertText(" 유지", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertEqual(model.draft(for: first), composedDraft)
        XCTAssertEqual(model.draft, "다른 대화 초안 유지")

        model.selectConversation(first)
        await waitUntil { editor.string == composedDraft }
        XCTAssertEqual(model.draft(for: second), "다른 대화 초안 유지")
    }

    func testInputGrowsThroughTenVisibleLinesAndCapsAtEleven() {
        let one = inputHeight("질문")
        let ten = inputHeight(Array(repeating: "질문", count: 10).joined(separator: "\n"))
        let eleven = inputHeight(Array(repeating: "질문", count: 11).joined(separator: "\n"))
        XCTAssertGreaterThan(ten, one)
        XCTAssertEqual(eleven, ten, accuracy: 1)
        // AppKit's empty insertion line can have slightly different metrics from a glyph line.
        XCTAssertEqual(inputHeight(Array(repeating: "질문", count: 9).joined(separator: "\n") + "\n"), ten, accuracy: 3)
        XCTAssertEqual(inputHeight(""), one, accuracy: 3)
    }

    func testInputHeightIncludesWrappedLinesAtCurrentWidth() {
        let text = String(repeating: "길게 작성한 질문 ", count: 10)
        XCTAssertGreaterThan(inputHeight(text, width: 180), inputHeight(text, width: 600))
    }

    func testShiftReturnKeepsScrollerDisabledUntilEleventhLine() {
        _ = NSApplication.shared
        var draft = "질문"
        let host = NSHostingView(rootView: ActivityChatInput(text: Binding(get: { draft }, set: { draft = $0 }), conversationID: UUID(), onSend: {}).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        guard let scroll = findScroll(host),
              let editor = scroll.documentView as? ActivityChatInput.ChatTextView else {
            return XCTFail("Native input was not mounted")
        }
        window.makeFirstResponder(editor)
        XCTAssertEqual(editor.string, "질문")
        XCTAssertFalse(scroll.hasVerticalScroller)
        for line in 2...11 {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.keyDown(with: returnEvent(modifiers: .shift))
            XCTAssertEqual(editor.string.components(separatedBy: "\n").count, line)
            // Check before SwiftUI has a chance to resize the viewport.
            XCTAssertEqual(scroll.hasVerticalScroller, line > 10, "Line \(line)")
        }
    }

    private func inputHeight(_ text: String, width: CGFloat = 300) -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ActivityChatInput(text: .constant(text), conversationID: UUID(), onSend: {}).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func returnEvent(modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: false, keyCode: 36)!
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the sample answer")
    }
}
