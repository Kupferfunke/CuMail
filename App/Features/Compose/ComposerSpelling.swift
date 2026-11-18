import AppKit
import SwiftUI

enum ComposerSpellingLanguage: String, CaseIterable, Identifiable {
    case automatic, german = "de", english = "en"
    static let preferenceKey = "compose.spellingLanguage.v1"
    static let correctionKey = "compose.automaticSpellingCorrection.v1"
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: "Automatisch"; case .german: "Deutsch"; case .english: "Englisch" }
    }
    static func stored(_ value: String) -> Self { Self(rawValue: value) ?? .automatic }

    @MainActor func activate(in checker: NSSpellChecker = .shared) {
        // AppKit's unified checker can still consult its per-application language
        // even with explicit orthography. Align both with CuMail's preference.
        checker.automaticallyIdentifiesLanguages = self == .automatic
        if self != .automatic { _ = checker.setLanguage(rawValue) }
    }

    func checkingRequest(types: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any])
        -> (types: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any]) {
        var options = options
        if self == .automatic {
            // Drop the previous language when changing back to automatic.
            options.removeValue(forKey: .orthography)
            return (types | NSTextCheckingResult.CheckingType.orthography.rawValue, options)
        }
        options[.orthography] = NSOrthography.defaultOrthography(forLanguage: rawValue)
        // Keep the explicitly chosen dictionary, rather than redetecting the
        // language of a short subject or an isolated misspelled word.
        return (types & ~NSTextCheckingResult.CheckingType.orthography.rawValue, options)
    }
}

/// One native text system for subject and body, each with its own spell-document
/// tag. This leaves the system-wide language and recipient fields unchanged.
class ComposerTextView: NSTextView {
    private(set) var spellingLanguage = ComposerSpellingLanguage.automatic
    private var configured = false
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }

    func configureSpelling(language: ComposerSpellingLanguage, automaticCorrection: Bool) {
        let changed = !configured || spellingLanguage != language
        spellingLanguage = language
        configured = true
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = automaticCorrection
        language.activate()
        if changed { refreshSpellingMarks() }
    }

    override func checkText(in range: NSRange, types checkingTypes: NSTextCheckingTypes,
                            options: [NSSpellChecker.OptionKey: Any] = [:]) {
        spellingLanguage.activate()
        let request = spellingLanguage.checkingRequest(types: checkingTypes, options: options)
        super.checkText(in: range, types: request.types, options: request.options)
    }

    func refreshSpellingMarks() {
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard range.length > 0 else { return }
        layoutManager?.removeTemporaryAttribute(.spellingState, forCharacterRange: range)
        // Rechecking existing drafts or switching languages must not rewrite
        // their text. AppKit applies automatic corrections only while typing.
        checkText(in: range, types: NSTextCheckingResult.CheckingType.spelling.rawValue)
    }
}

final class ComposerSubjectCell: NSTextFieldCell {
    let spellingEditor = ComposerTextView()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        spellingEditor.isFieldEditor = true
        spellingEditor.isRichText = false
        spellingEditor.allowsUndo = true
        return spellingEditor
    }
}

struct ComposerSubjectField: NSViewRepresentable {
    @Binding var value: String
    let enabled: Bool
    let language: ComposerSpellingLanguage
    let automaticCorrection: Bool
    let textColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.cell = ComposerSubjectCell(textCell: "")
        field.isEditable = true; field.isSelectable = true
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.placeholderString = "Betreff"
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("compose-subject"); field.setAccessibilityLabel("Betreff")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = enabled; field.textColor = textColor
        if field.stringValue != value { field.stringValue = value }
        if let editor = (field.cell as? ComposerSubjectCell)?.spellingEditor {
            editor.configureSpelling(language: language, automaticCorrection: automaticCorrection)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerSubjectField
        init(_ parent: ComposerSubjectField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? ComposerTextView else { return }
            // AppKit replaces a field editor's backing string on each focus
            // session; undo ranges from its previous session are no longer valid.
            editor.undoManager?.removeAllActions()
            editor.configureSpelling(language: parent.language, automaticCorrection: parent.automaticCorrection)
            editor.refreshSpellingMarks()
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.value = field.stringValue }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            // Includes any final correction accepted when focus leaves the field.
            if let field = notification.object as? NSTextField {
                parent.value = field.stringValue
                (field.cell as? ComposerSubjectCell)?.spellingEditor.undoManager?.removeAllActions()
            }
        }
    }
}

struct ComposerBodyEditor: NSViewRepresentable {
    @Binding var value: String
    let enabled: Bool
    let language: ComposerSpellingLanguage
    let automaticCorrection: Bool
    let textColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        text.isRichText = false; text.importsGraphics = false
        text.drawsBackground = false; text.font = .systemFont(ofSize: 14)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.allowsUndo = true
        text.setAccessibilityIdentifier("compose-body"); text.setAccessibilityLabel("Nachrichtentext")
        text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let text = scroll.documentView as? ComposerTextView else { return }
        text.isEditable = enabled; text.textColor = textColor
        if text.string != value && !text.hasMarkedText() {
            let selection = text.selectedRange()
            text.undoManager?.removeAllActions()
            text.string = value
            let length = (value as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
            text.refreshSpellingMarks()
        }
        text.configureSpelling(language: language, automaticCorrection: automaticCorrection)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerBodyEditor
        init(_ parent: ComposerBodyEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let text = notification.object as? NSTextView { parent.value = text.string }
        }
        func textDidBeginEditing(_ notification: Notification) {
            if let text = notification.object as? ComposerTextView {
                text.configureSpelling(language: parent.language, automaticCorrection: parent.automaticCorrection)
            }
        }
    }
}
