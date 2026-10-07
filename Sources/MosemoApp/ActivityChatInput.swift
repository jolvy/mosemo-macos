import AppKit
import SwiftUI

/// NSTextView keeps Return used to commit marked Korean text out of the send path.
struct ActivityChatInput: NSViewRepresentable {
    @Binding var text: String
    let conversationID: UUID
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = ChatTextView()
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.setAccessibilityLabel("활동에 대해 질문하기")
        editor.setAccessibilityIdentifier("chat-input")
        scroll.documentView = editor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ChatTextView else { return }
        if context.coordinator.parent.conversationID != conversationID, editor.hasMarkedText() {
            // Finish composition while the coordinator still owns the previous draft.
            editor.unmarkText()
            context.coordinator.parent.text = editor.string
        }
        context.coordinator.parent = self
        editor.onSend = onSend
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.updateScrolling()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let editor = nsView.documentView as? ChatTextView else { return nil }
        let width = proposal.width ?? max(1, nsView.bounds.width)
        return CGSize(width: width, height: editor.fittingHeight(for: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ActivityChatInput
        init(_ parent: ActivityChatInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }

    final class ChatTextView: NSTextView {
        var onSend: (() -> Void)?
        func fittingHeight(for width: CGFloat) -> CGFloat {
            guard let textContainer, let layoutManager, let font else { return 0 }
            textContainer.containerSize = NSSize(
                width: max(1, width - textContainerInset.width * 2),
                height: .greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            var height = layoutManager.defaultLineHeight(for: font)
            var lineCount = 0
            layoutManager.enumerateLineFragments(
                forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
            ) { rect, _, _, _, _ in
                if lineCount < 10 { height = max(height, rect.maxY) }
                lineCount += 1
            }
            if layoutManager.extraLineFragmentTextContainer === textContainer {
                if lineCount < 10 {
                    height = max(height, layoutManager.extraLineFragmentRect.maxY)
                }
                lineCount += 1
            }
            // Autohiding alone flashes while the old viewport waits for SwiftUI to grow.
            // Keep the scroller absent until the content actually exceeds ten lines.
            enclosingScrollView?.hasVerticalScroller = lineCount > 10
            return ceil(height + textContainerInset.height * 2)
        }

        func updateScrolling() {
            guard let scroll = enclosingScrollView else { return }
            _ = fittingHeight(for: max(1, scroll.contentSize.width))
        }

        override func didChangeText() {
            super.didChangeText()
            updateScrolling()
        }

        override func keyDown(with event: NSEvent) {
            if (event.keyCode == 36 || event.keyCode == 76),
               !event.modifierFlags.contains(.shift), !hasMarkedText() {
                onSend?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
