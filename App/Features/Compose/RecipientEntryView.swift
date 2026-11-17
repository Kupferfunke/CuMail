import AppKit
import SwiftUI
import MailApplication

struct RecipientCompletionContext: Equatable {
    let value: String
    let range: NSRange
    let prefix: String
    init(value: String, selection: NSRange) {
        self.value = value
        let text = value as NSString, caret = min(max(0, selection.location), text.length)
        let separators = CharacterSet(charactersIn: ",;")
        let before = text.rangeOfCharacter(from: separators, options: .backwards, range: NSRange(location: 0, length: caret))
        let after = text.rangeOfCharacter(from: separators, options: [], range: NSRange(location: caret, length: text.length - caret))
        let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
        let end = after.location == NSNotFound ? text.length : after.location
        range = NSRange(location: start, length: end - start)
        prefix = text.substring(with: NSRange(location: start, length: caret - start)).trimmingCharacters(in: .whitespaces)
    }
    func inserting(_ address: String) -> (value: String, caret: NSRange) {
        let text = value as NSString
        let replacement = (range.location == 0 ? "" : " ") + address + (NSMaxRange(range) == text.length ? ", " : "")
        return (text.replacingCharacters(in: range, with: replacement), NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }
    func suggestions(from history: [UsedRecipient], excluding otherFields: Set<String>) -> [UsedRecipient] {
        func folded(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_CH")) }
        let query = folded(prefix)
        guard !query.isEmpty else { return [] }
        let remaining = (value as NSString).replacingCharacters(in: range, with: "")
        let used = otherFields.union(remaining.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return history.filter { recipient in
            !used.contains(recipient.address.lowercased()) &&
            (folded(recipient.address).hasPrefix(query) || folded(recipient.name).hasPrefix(query) || recipient.name.split(separator: " ").contains { folded(String($0)).hasPrefix(query) })
        }.sorted {
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.address < $1.address
        }
    }
}

struct RecipientEntryView: View {
    @Binding var value: String
    let label: String
    let identifier: String
    let history: [UsedRecipient]
    let otherAddresses: Set<String>
    let enabled: Bool
    @Environment(\.colorScheme) private var scheme
    @ViewState private var focused = false
    @ViewState private var selection = NSRange(location: 0, length: 0)
    @ViewState private var selectedIndex = 0
    @ViewState private var dismissed = false
    @ViewState private var caretRevision = 0
    private var completion: RecipientCompletionContext { .init(value: value, selection: selection) }
    private var suggestions: [UsedRecipient] { completion.suggestions(from: history, excluding: otherAddresses) }
    private var showing: Bool { focused && enabled && !dismissed && !suggestions.isEmpty }
    var body: some View {
        HStack {
            Text(label).frame(width: 55, alignment: .leading).foregroundStyle(Brand.secondary(scheme))
            RecipientTextField(value: $value, identifier: identifier, label: label, enabled: enabled,
                selection: selection, caretRevision: caretRevision,
                focusChanged: { focused = $0; if !$0 { dismissed = true } },
                selectionChanged: { selection = $0 },
                edited: { dismissed = false; selectedIndex = 0 }, command: handleCommand)
                .frame(height: 22)
                .overlay(alignment: .topLeading) {
                    if showing {
                        suggestionsView.offset(y: 27)
                    }
                }
        }.padding(.vertical, 4).zIndex(showing ? 10 : 0)
    }
    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bisherige Empfänger").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.secondary(scheme)).padding(.horizontal, 12).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, recipient in
                            Button { accept(recipient) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "person.crop.circle").font(.system(size: 19)).foregroundStyle(Brand.accent(scheme))
                                    VStack(alignment: .leading, spacing: 2) {
                                        if !recipient.name.isEmpty { Text(recipient.name).font(.system(size: 12, weight: .medium)) }
                                        Text(recipient.address).font(.system(size: 12)).foregroundStyle(recipient.name.isEmpty ? Brand.text(scheme) : Brand.secondary(scheme))
                                    }
                                    Spacer(minLength: 8)
                                }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == selectedIndex ? Brand.accent(scheme).opacity(0.12) : .clear)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).focusable(false).id(recipient.id).accessibilityLabel(recipient.name + " " + recipient.address)
                        }
                    }
                }.frame(height: min(CGFloat(suggestions.count) * 48, 240))
                    .onChange(of: selectedIndex) { _, index in
                        guard suggestions.indices.contains(index) else { return }
                        proxy.scrollTo(suggestions[index].id, anchor: .center)
                    }
            }
        }.background(Brand.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.secondary(scheme).opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.13), radius: 10, y: 4)
            .accessibilityIdentifier(identifier + "-suggestions")
    }
    private func accept(_ recipient: UsedRecipient) {
        let result = completion.inserting(recipient.address)
        value = result.value; selection = result.caret; caretRevision += 1
        dismissed = true; selectedIndex = 0
    }
    private func handleCommand(_ command: Selector) -> Bool {
        guard showing else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)): selectedIndex = min(selectedIndex + 1, suggestions.count - 1)
        case #selector(NSResponder.moveUp(_:)): selectedIndex = max(selectedIndex - 1, 0)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            accept(suggestions[min(selectedIndex, suggestions.count - 1)])
        case #selector(NSResponder.cancelOperation(_:)): dismissed = true
        default: return false
        }
        return true
    }
}

/// Use the field editor's commands and UTF-16 caret so suggestions also work
/// when editing an address in the middle of a multi-recipient field.
struct RecipientTextField: NSViewRepresentable {
    @Binding var value: String
    let identifier: String
    let label: String
    let enabled: Bool
    let selection: NSRange
    let caretRevision: Int
    let focusChanged: (Bool) -> Void
    let selectionChanged: (NSRange) -> Void
    let edited: () -> Void
    let command: (Selector) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.placeholderString = "E-Mail-Adressen, mit Komma trennen"
        field.setAccessibilityIdentifier(identifier); field.setAccessibilityLabel(label)
        field.delegate = context.coordinator; field.lineBreakMode = .byClipping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = enabled
        if field.stringValue != value { field.stringValue = value }
        if context.coordinator.appliedCaretRevision != caretRevision {
            context.coordinator.appliedCaretRevision = caretRevision
            field.window?.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RecipientTextField
        var appliedCaretRevision = 0

        init(_ parent: RecipientTextField) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focusChanged(true)
            guard let field = notification.object as? NSTextField, let editor = field.currentEditor() as? NSTextView else { return }
            parent.selectionChanged(editor.selectedRange())
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: editor)
        }
        @objc private func selectionChanged(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.selectionChanged(editor.selectedRange()) }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.value = field.stringValue
            if let editor = field.currentEditor() as? NSTextView { parent.selectionChanged(editor.selectedRange()) }
            parent.edited()
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.focusChanged(false)
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            parent.command(commandSelector)
        }
    }
}
