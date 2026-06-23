import SwiftUI
import AppKit

// NSTextView wrapped for SwiftUI. SwiftUI's TextEditor isn't built for code
// (no monospace font, smart-quotes by default, no line-tracking), so we host
// the same NSTextView the original Obj-C editor used.
struct CodeEditorView: NSViewRepresentable {

    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]

        let contentSize = scrollView.contentSize
        let tv = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        tv.minSize = NSSize(width: 0, height: contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 8, height: 8)

        // Code-appropriate behavior: plain text, no "smart" substitutions.
        tv.isRichText = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.allowsUndo = true
        tv.delegate = context.coordinator

        let font = Self.editorFont
        tv.font = font

        // Force the system semantic colors. Without these, NSTextView in our
        // SwiftUI host has shown up as black text on dark background — the
        // dynamic NSColor.textColor wasn't getting applied for some reason.
        // Setting them explicitly makes the editor flip with light/dark mode.
        tv.textColor = NSColor.textColor
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.insertionPointColor = NSColor.textColor
        tv.drawsBackground = true

        // 4-space-wide soft tabs feel.
        let pstyle = NSMutableParagraphStyle()
        let charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        pstyle.tabStops = []
        pstyle.defaultTabInterval = charWidth * 4
        tv.defaultParagraphStyle = pstyle
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: pstyle,
        ]

        tv.string = text
        scrollView.documentView = tv
        context.coordinator.textView = tv
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text {
            // Outside change (e.g. loaded a new file). Reset the text and
            // reassert ALL rendering attributes — setString clears typing
            // attrs AND has been observed to drop textColor too.
            tv.string = text
            tv.font = Self.editorFont
            tv.textColor = NSColor.textColor
        }
    }

    static var editorFont: NSFont {
        NSFont(name: "Menlo", size: 13) ?? NSFont.userFixedPitchFont(ofSize: 13) ?? NSFont.systemFont(ofSize: 13)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Only propagate if the string actually differs, to avoid the
            // pathological "update binding → updateNSView → re-set string"
            // loop when both sides match.
            if parent.text != tv.string {
                parent.text = tv.string
            }
        }
    }
}
