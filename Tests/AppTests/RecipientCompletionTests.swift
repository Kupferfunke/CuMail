import Foundation
import Testing
import MailApplication
@testable import MikeMailHub

struct RecipientCompletionTests {
    @Test func prefixesFilterFromFirstLetterAndFrequencyWinsOverAlphabet() {
        let history = [UsedRecipient(address: "anna@example.invalid", name: "Anna", useCount: 2, lastUsed: .distantPast),
                       UsedRecipient(address: "alex@example.invalid", name: "Alex", useCount: 8, lastUsed: .distantPast),
                       UsedRecipient(address: "maria@example.invalid", name: "Maria", useCount: 99, lastUsed: .distantPast)]
        func matching(_ input: String) -> [String] {
            RecipientCompletionContext(value: input, selection: NSRange(location: input.utf16.count, length: 0)).suggestions(from: history, excluding: []).map(\.address)
        }
        #expect(matching("").isEmpty)
        #expect(matching("A") == ["alex@example.invalid", "anna@example.invalid"])
        #expect(matching("an") == ["anna@example.invalid"])
        #expect(matching("az").isEmpty)
        #expect(matching("anna@example.invalid, a") == ["alex@example.invalid"])
    }
    @Test func selectingReplacesOnlyCurrentAddressAndPreservesTheRest() {
        let input = "first@example.invalid; an; last@example.invalid"
        let caret = (input as NSString).range(of: "an;").location + 2
        let context = RecipientCompletionContext(value: input, selection: NSRange(location: caret, length: 0))
        let result = context.inserting("anna@example.invalid")
        #expect(result.value == "first@example.invalid; anna@example.invalid; last@example.invalid")
        #expect((result.value as NSString).substring(to: result.caret.location).hasSuffix("anna@example.invalid"))
        let last = RecipientCompletionContext(value: "first@example.invalid, an", selection: NSRange(location: 25, length: 0)).inserting("anna@example.invalid")
        #expect(last.value == "first@example.invalid, anna@example.invalid, ")
    }
    @Test func otherFieldsAreExcludedAndAccentedNamesCanBeFound() {
        let person = UsedRecipient(address: "someone@example.invalid", name: "Änne Beispiel", useCount: 1, lastUsed: .distantPast)
        let context = RecipientCompletionContext(value: "an", selection: NSRange(location: 2, length: 0))
        #expect(context.suggestions(from: [person], excluding: []).count == 1)
        #expect(context.suggestions(from: [person], excluding: [person.address]).isEmpty)
    }
}
