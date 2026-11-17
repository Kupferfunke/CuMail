import Foundation
import Testing
@testable import MailDomain
import MailApplication
import MailDemo

struct DomainTests {
    @Test(arguments: ["", "123", "00000000-0000-0000-0000-000000000000", "../message", "30000000-0000-4000-8000-000000000001 "])
    func invalidLocalIDs(value: String) { #expect(throws: DomainError.invalidID) { try MessageID(string: value) } }

    @Test func decodedIDsCannotBypassValidation() throws {
        let data = Data("\"00000000-0000-0000-0000-000000000000\"".utf8)
        #expect(throws: DomainError.invalidID) { try JSONDecoder().decode(MessageID.self, from: data) }
    }
    @Test(arguments: ["a@example.com\r\nBcc:other@example.com", "", "a@@example.com", "a @example.com"])
    func rejectsMalformedAddresses(value: String) { #expect(throws: DomainError.invalidAddress) { try EmailAddress(value) } }

    @Test func fixturesAreDeterministicAndHaveNoRealAddresses() throws {
        let first = try SyntheticFixtures.make(), second = try SyntheticFixtures.make()
        #expect(first.snapshot.messages == second.snapshot.messages)
        #expect(first.contents == second.contents)
        #expect(first.snapshot.accounts.count == 3)
        #expect(first.snapshot.messages.count == 10)
        #expect(first.snapshot.messages.allSatisfy { $0.sender.address.value.hasSuffix("@example.com") })
    }
    @Test func rejectsDuplicateLocalIdentity() throws {
        let snapshot = try SyntheticFixtures.make().snapshot
        #expect(throws: DomainError.duplicateID) {
            try MailSnapshot(accounts: snapshot.accounts, folders: snapshot.folders, threads: snapshot.threads,
                             messages: snapshot.messages + [snapshot.messages[0]])
        }
    }
    @Test func rejectsUnknownAccount() throws {
        let snapshot = try SyntheticFixtures.make().snapshot
        #expect(throws: DomainError.unknownAccount) {
            try MailSnapshot(accounts: [], folders: snapshot.folders, threads: snapshot.threads, messages: snapshot.messages)
        }
    }
    @Test func rejectsCrossAccountThread() throws {
        let snapshot = try SyntheticFixtures.make().snapshot
        let incorrect = MailThread(id: snapshot.threads[0].id, accountID: snapshot.accounts[1].id, subject: "Test")
        #expect(throws: DomainError.crossAccountReference) {
            try MailSnapshot(accounts: snapshot.accounts, folders: snapshot.folders,
                             threads: [incorrect] + snapshot.threads.dropFirst(), messages: snapshot.messages)
        }
    }
    @Test func rejectsCrossAccountFolder() throws {
        let snapshot = try SyntheticFixtures.make().snapshot
        let incorrect = try MailFolder(id: snapshot.folders[0].id, accountID: snapshot.accounts[1].id, providerID: "inbox", name: "Inbox", role: .inbox)
        #expect(throws: DomainError.crossAccountReference) {
            try MailSnapshot(accounts: snapshot.accounts, folders: [incorrect] + snapshot.folders.dropFirst(),
                             threads: snapshot.threads, messages: snapshot.messages)
        }
    }
    @Test func sameProviderIdentifierInTwoAccountsRemainsDistinct() throws {
        let a = try AccountID(string: "10000000-0000-4000-8000-000000000001")
        let b = try AccountID(string: "10000000-0000-4000-8000-000000000002")
        let accounts = try [MailAccount(id: a, name: "A", address: EmailAddress("a@example.com"), provider: .gmail),
                            MailAccount(id: b, name: "B", address: EmailAddress("b@example.com"), provider: .gmail)]
        let m1 = try makeMessage(account: a, number: 1), m2 = try makeMessage(account: b, number: 2)
        let snapshot = try MailSnapshot(accounts: accounts, folders: [], threads: [], messages: [m1,m2])
        #expect(snapshot.messages.count == 2)
        #expect(m1.locator == m2.locator)
        #expect(m1.id != m2.id)
        #expect(m1.internetMessageID == nil)
    }
    @Test func imapIdentityUsesMailboxAndUIDValidity() {
        let base = ProviderLocator.imap(mailbox: "INBOX", uidValidity: 1, uid: 42)
        #expect(base != .imap(mailbox: "INBOX", uidValidity: 2, uid: 42))
        #expect(base != .imap(mailbox: "Archive", uidValidity: 1, uid: 42))
        #expect(!ProviderLocator.imap(mailbox: "INBOX", uidValidity: 0, uid: 42).isValid)
        #expect(!ProviderLocator.imap(mailbox: "INBOX", uidValidity: 1, uid: 0).isValid)
    }
    @Test func gmailLabelsDoNotDuplicateMessages() async throws {
        let data = try SyntheticFixtures.make()
        let account = data.snapshot.accounts[1]
        let folders = data.snapshot.folders.filter { $0.accountID == account.id }
        let message = try makeMessage(account: account.id, number: 42, folderIDs: Set(folders.prefix(2).map(\.id)))
        let snapshot = try MailSnapshot(accounts: [account], folders: folders, threads: [], messages: [message])
        let repo = InMemoryMailRepository(snapshot: snapshot)
        let result = try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: AccessScope(accountIDs: [account.id]))
        #expect(result.items.count == 1)
    }
    @Test func negativeAttachmentSizeRejected() throws {
        let data = try SyntheticFixtures.make().snapshot
        #expect(throws: DomainError.invalidSize) {
            try AttachmentMetadata(id: AttachmentID(), messageID: data.messages[0].id, accountID: data.accounts[0].id,
                                   filename: "test.pdf", mimeType: "application/pdf", byteCount: -1)
        }
    }
    private func makeMessage(account: AccountID, number: Int, folderIDs: Set<FolderID> = []) throws -> MailMessage {
        try MailMessage(id: MessageID(string: String(format: "30000000-0000-4000-8000-%012d", number)), accountID: account,
                        locator: .gmail(id: "same-opaque-provider-id"), threadID: nil, folderIDs: folderIDs,
                        subject: "Test", sender: MailPerson(name: "Demo", address: EmailAddress("demo@example.com")), recipients: [],
                        receivedAt: Date(timeIntervalSince1970: 1), isUnread: true, isFlagged: false, preview: nil)
    }
}
