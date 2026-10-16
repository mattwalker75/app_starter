// A box for a start or stop command that may take several lines (Matt: "just in case an app needs a second
// command or more"). An NSTextView the app owns — monospaced, no smart quotes or dashes (they would break a
// command), no spelling fixes — that grows from `minLines` up to `maxLines` and scrolls after that.
import SwiftUI
import AppKit

struct ScriptEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var minLines = 2
    var maxLines = 8
    var label: String?

    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static func height(lines: Int) -> CGFloat { CGFloat(lines) * (font.ascender - font.descender + font.leading + 2) + 12 }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.string = text
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        if let label { tv.setAccessibilityLabel(label) }
        context.coordinator.placeholder(tv, placeholder)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        // while the user types, the view is the truth; a change from elsewhere is applied
        if tv.window?.firstResponder !== tv, tv.string != text { tv.string = text }
        context.coordinator.placeholder(tv, placeholder)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let lines = max(minLines, min(maxLines, text.split(separator: "\n", omittingEmptySubsequences: false).count))
        return CGSize(width: proposal.width ?? 400, height: Self.height(lines: lines))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptEditor
        private var hint: NSTextField?
        init(_ p: ScriptEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            let value = tv.string
            hint?.isHidden = !value.isEmpty
            DispatchQueue.main.async { [self] in if parent.text != value { parent.text = value } }
        }
        func placeholder(_ tv: NSTextView, _ s: String) {
            if hint == nil, !s.isEmpty {
                let l = NSTextField(labelWithString: s)
                l.font = ScriptEditor.font; l.textColor = .placeholderTextColor
                l.translatesAutoresizingMaskIntoConstraints = false
                tv.addSubview(l)
                NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 9), l.topAnchor.constraint(equalTo: tv.topAnchor, constant: 6)])
                hint = l
            }
            hint?.stringValue = s
            hint?.isHidden = !tv.string.isEmpty
        }
    }
}
