import Foundation
import Testing
import MailDomain
import MailApplication
import MailDemo

struct SecurityTests {
    private let valid = "30000000-0000-4000-8000-000000000001"
    @Test func parsesNavigationOnly() throws {
        #expect(try DeepLinkParser.parse("mikemail://message/\(valid)") == .message(MessageID(string: valid)))
        #expect(try DeepLinkParser.parse("mikemail://thread/\(valid)") == .thread(ThreadID(string: valid)))
    }
    @Test(arguments: ["https://message/", "mikemail://send/", "mikemail://delete/", "mikemail://user@message/", "mikemail://message:8080/", "mikemail://message//"])
    func rejectsUnexpectedAuthority(prefix: String) {
        #expect(throws: DeepLinkError.invalid) { try DeepLinkParser.parse(prefix + valid) }
    }
    @Test(arguments: ["?send=true", "?", "#fragment", "#", "/", "/../../foo", "%2f", " "])
    func rejectsExtraData(suffix: String) {
        #expect(throws: DeepLinkError.invalid) { try DeepLinkParser.parse("mikemail://message/" + valid + suffix) }
    }
    @Test func rejectsEncodedOrOversizedLinks() {
        #expect(throws: DeepLinkError.invalid) { try DeepLinkParser.parse("mikemail://message/%33" + valid.dropFirst()) }
        #expect(throws: DeepLinkError.invalid) { try DeepLinkParser.parse("mikemail://message/" + String(repeating: "a", count: 3000)) }
    }
    @Test func routeMustBelongToAccessibleAccount() throws {
        let snapshot = try SyntheticFixtures.make().snapshot
        let route = MailRoute.message(snapshot.messages[0].id)
        #expect(throws: DeepLinkError.forbidden) { try DeepLinkParser.authorize(route, snapshot: snapshot, allowedAccounts: [snapshot.accounts[1].id]) }
        try DeepLinkParser.authorize(route, snapshot: snapshot, allowedAccounts: [snapshot.accounts[0].id])
    }
    @Test func unknownTargetRejected() throws {
        let snapshot = try SyntheticFixtures.make().snapshot
        let route = MailRoute.message(try MessageID(string: "30000000-0000-4000-8000-999999999999"))
        #expect(throws: DeepLinkError.notFound) { try DeepLinkParser.authorize(route, snapshot: snapshot, allowedAccounts: Set(snapshot.accounts.map(\.id))) }
    }
    @Test func forbiddenDataNeverEntersIndex() {
        let policy = StoragePolicy()
        for value in [StorageClass.originalMIME, .htmlBody, .attachmentBytes, .credential, .ownDraft] {
            #expect(!policy.permits(value, at: .index, textIndexEnabled: true))
        }
        #expect(policy.permits(.messageMetadata, at: .index))
        #expect(policy.permits(.attachmentMetadata, at: .index))
        #expect(!policy.permits(.extractedText, at: .index))
        #expect(policy.permits(.extractedText, at: .index, textIndexEnabled: true))
        #expect(!policy.permits(.credential, at: .temporaryFile))
        #expect(policy.permits(.credential, at: .keychain))
    }
    @Test func textBudgetBoundariesAndOverflow() {
        let p = StoragePolicy()
        #expect(p.mayIndexText(byteCount: p.extractedTextLimit, currentAccountBytes: 0, enabled: true))
        #expect(!p.mayIndexText(byteCount: p.extractedTextLimit + 1, currentAccountBytes: 0, enabled: true))
        #expect(!p.mayIndexText(byteCount: 1, currentAccountBytes: p.accountTextBudget, enabled: true))
        #expect(!p.mayIndexText(byteCount: Int.max, currentAccountBytes: Int.max, enabled: true))
        #expect(!p.mayIndexText(byteCount: -1, currentAccountBytes: 0, enabled: true))
        #expect(!p.mayIndexText(byteCount: 10, currentAccountBytes: -1, enabled: true))
        #expect(!p.mayIndexText(byteCount: 1, currentAccountBytes: 0, enabled: false))
    }
    @Test func cleanupProtectsActiveFilesAndExports() {
        let p = StoragePolicy(), now = Date(timeIntervalSince1970: 100_000), old = Date(timeIntervalSince1970: 0)
        #expect(p.shouldRemoveTemporary(lastUsed: old, now: now, isActive: false, isUserExport: false))
        #expect(!p.shouldRemoveTemporary(lastUsed: old, now: now, isActive: true, isUserExport: false))
        #expect(!p.shouldRemoveTemporary(lastUsed: old, now: now, isActive: false, isUserExport: true))
        #expect(!p.shouldRemoveTemporary(lastUsed: now, now: now, isActive: false, isUserExport: false))
    }
    @Test func credentialDoubleKeepsAccountAndPurposeSeparate() async throws {
        let data = try SyntheticFixtures.make().snapshot
        let store = InMemoryCredentialStore()
        let a = CredentialReference(accountID: data.accounts[0].id, purpose: .incomingPassword)
        let b = CredentialReference(accountID: data.accounts[1].id, purpose: .incomingPassword)
        let smtp = CredentialReference(accountID: data.accounts[0].id, purpose: .outgoingPassword)
        await store.save(Data("synthetic-only".utf8), for: a)
        #expect(await store.read(b) == nil)
        #expect(await store.read(smtp) == nil)
        await store.save(Data("replacement".utf8), for: a)
        #expect(await store.read(a) == Data("replacement".utf8))
        await store.delete(a)
        #expect(await store.read(a) == nil)
    }
}
