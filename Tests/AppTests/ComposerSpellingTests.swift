import AppKit
import SwiftUI
import Testing
@testable import MikeMailHub

@MainActor @Suite(.serialized)
struct ComposerSpellingTests {
    @Test func fixedLanguagesUseTheirOwnDictionaryAndAutomaticDropsThePreviousLanguage() throws {
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.orthography.rawValue
        let old: [NSSpellChecker.OptionKey: Any] = [.orthography: NSOrthography.defaultOrthography(forLanguage: "en-US")]
        let german = ComposerSpellingLanguage.german.checkingRequest(types: types, options: old)
        #expect(german.types & NSTextCheckingResult.CheckingType.orthography.rawValue == 0)
        #expect((german.options[.orthography] as? NSOrthography)?.dominantLanguage == "de")
        let auto = ComposerSpellingLanguage.automatic.checkingRequest(types: german.types, options: german.options)
        #expect(auto.options[.orthography] == nil)
        #expect(auto.types & NSTextCheckingResult.CheckingType.orthography.rawValue != 0)

        let checker = NSSpellChecker.shared, tag = NSSpellChecker.uniqueSpellDocumentTag()
        let oldLanguage = checker.language(), oldAutomatic = checker.automaticallyIdentifiesLanguages
        defer {
            checker.closeSpellDocument(withTag: tag)
            _ = checker.setLanguage(oldLanguage); checker.automaticallyIdentifiesLanguages = oldAutomatic
        }
        func spelling(_ text: String, language: ComposerSpellingLanguage) -> [NSTextCheckingResult] {
            language.activate(in: checker)
            let request = language.checkingRequest(types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
            return checker.check(text, range: NSRange(location: 0, length: text.utf16.count), types: request.types,
                options: request.options, inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil)
                .filter { $0.resultType == .spelling }
        }
        #expect(spelling("Freundliche Grüsse und einen schönen Nachmittag", language: .german).isEmpty)
        #expect(!spelling("Nachrciht", language: .german).isEmpty)
        #expect(spelling("Thank you for your message", language: .english).isEmpty)
        #expect(!spelling("recieve", language: .english).isEmpty)
        #expect(spelling("glücklich", language: .german).isEmpty)
        #expect(!spelling("glücklich", language: .english).isEmpty)
    }

    @Test func changingLanguageRechecksWithoutRewritingExistingDraftOrSelection() async throws {
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let content = "Recieve meine Nachrciht.\nÄöü und 👋 bleiben erhalten."
        view.string = content; view.setSelectedRange(NSRange(location: 7, length: 5))
        for language in ComposerSpellingLanguage.allCases {
            view.configureSpelling(language: language, automaticCorrection: true)
            #expect(view.isContinuousSpellCheckingEnabled && view.isAutomaticSpellingCorrectionEnabled)
            #expect(view.spellingLanguage == language)
            try await Task.sleep(for: .milliseconds(60))
            #expect(view.string == content)
            #expect(view.selectedRange() == NSRange(location: 7, length: 5))
        }
        view.configureSpelling(language: .german, automaticCorrection: false)
        #expect(view.isContinuousSpellCheckingEnabled && !view.isAutomaticSpellingCorrectionEnabled)
    }

    @Test func subjectUsesDedicatedFieldEditorAndBodyEditsReachBindingAndUndo() async throws {
        var subject = "Meine Nachrciht", body = "Hoi 👋\n"
        let subjectBinding = Binding(get: { subject }, set: { subject = $0 })
        let bodyBinding = Binding(get: { body }, set: { body = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = VStack {
            ComposerSubjectField(value: subjectBinding, enabled: true, language: .german,
                automaticCorrection: true, textColor: .labelColor).frame(height: 22)
            ComposerBodyEditor(value: bodyBinding, enabled: true, language: .english,
                automaticCorrection: false, textColor: .labelColor)
        }
        window.contentView = NSHostingView(rootView: root)
        defer { window.close(); window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try #require(window.contentView))
        let field = try #require(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "compose-subject" || $0.accessibilityIdentifier() == "compose-subject" })
        #expect(field.isEditable && field.isSelectable)
        #expect(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? ComposerTextView)
        #expect(editor.isContinuousSpellCheckingEnabled && editor.isAutomaticSpellingCorrectionEnabled)
        #expect(editor.spellingLanguage == .german)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" heute", replacementRange: editor.selectedRange())
        #expect(subject == "Meine Nachrciht heute")

        let text = try #require(views.compactMap { $0 as? ComposerTextView }.first { !$0.isFieldEditor })
        #expect(window.makeFirstResponder(text))
        #expect(text.spellingLanguage == .english && !text.isAutomaticSpellingCorrectionEnabled)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertText("Thank you", replacementRange: text.selectedRange())
        #expect(body == "Hoi 👋\nThank you")
        text.breakUndoCoalescing()
        let undo = try #require(text.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(body == "Hoi 👋\n")
    }

    @Test func languageAndCorrectionPreferencesSurviveReload() throws {
        let suite = "CuMail-spelling-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ComposerSpellingLanguage.german.rawValue, forKey: ComposerSpellingLanguage.preferenceKey)
        defaults.set(false, forKey: ComposerSpellingLanguage.correctionKey)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(ComposerSpellingLanguage.stored(reopened.string(forKey: ComposerSpellingLanguage.preferenceKey) ?? "") == .german)
        #expect(!reopened.bool(forKey: ComposerSpellingLanguage.correctionKey))
        #expect(ComposerSpellingLanguage.stored("unknown") == .automatic)
    }
}
