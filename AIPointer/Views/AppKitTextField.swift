import SwiftUI
import AppKit

/// NSTextField subclass with orange insertion point (caret).
/// Also suppresses fn/Globe key to prevent emoji picker from being triggered
/// through the text input context when this field has focus.
class OrangeCaretTextField: NSTextField {
    static let caretColor = NSColor(red: 0xEC / 255, green: 0x68 / 255, blue: 0x2C / 255, alpha: 1)

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = Self.caretColor
        }
        return result
    }

    /// Block fn/Globe from reaching NSTextInputContext (which would trigger the emoji picker).
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 63 { return }
        super.flagsChanged(with: event)
    }

    /// Provide a custom field editor that also blocks fn in its responder chain.
    private static let sharedFieldEditor = FnSuppressingFieldEditor()

    /// Returns a custom field editor that suppresses fn key events.
    /// Call this from the window delegate's `windowWillReturnFieldEditor(to:)`.
    static var fnSuppressingFieldEditor: NSTextView { sharedFieldEditor }
}

/// Custom field editor (NSTextView) that blocks fn/Globe key events.
/// The field editor is the actual text editing view inside an NSTextField,
/// and fn events can reach NSTextInputContext through it.
class FnSuppressingFieldEditor: NSTextView {
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 63 { return }
        super.flagsChanged(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        insertionPointColor = OrangeCaretTextField.caretColor
        return result
    }
}

/// AppKit NSTextField wrapped for SwiftUI — bypasses SwiftUI @FocusState issues in NSPanel.
/// Auto-focuses when added to a window by calling makeFirstResponder directly.
struct AppKitTextField: NSViewRepresentable {
    typealias NSViewType = OrangeCaretTextField

    @Binding var text: String
    var placeholder: String = ""
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onTab: (() -> Bool)?    // returns true if handled
    var isDisabled: Bool = false
    var autoFocus: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> OrangeCaretTextField {
        let tf = OrangeCaretTextField()
        tf.focusRingType = .none
        tf.isBordered = false
        tf.drawsBackground = false
        tf.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        tf.textColor = .white
        tf.placeholderString = placeholder
        tf.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.3),
                         .font: NSFont.systemFont(ofSize: 14, weight: .medium)]
        )
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.delegate = context.coordinator
        tf.isEnabled = !isDisabled

        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                tf.window?.makeFirstResponder(tf)
            }
        }

        return tf
    }

    func updateNSView(_ nsView: OrangeCaretTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        let shouldEnable = !isDisabled
        if nsView.isEnabled != shouldEnable {
            nsView.isEnabled = shouldEnable
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitTextField
        init(_ parent: AppKitTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // If tab handler exists and would handle it (skill completion confirm), do that first
                if let onTab = parent.onTab, onTab() {
                    return true
                }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onUpArrow?()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onDownArrow?()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if let onTab = parent.onTab, onTab() {
                    return true
                }
            }
            return false
        }
    }
}
