import Foundation
import Testing
import MailDomain
import MailApplication
import MailDemo

struct RepositoryTests {
    @Test func unauthorizedMetadataBodyAndThreadAreUnavailable() async throws {
        let data = try SyntheticFixtures.make(), repo = data.repository()
        let restricted = AccessScope(accountIDs: [data.snapshot.accounts[1].id])
        let message = data.snapshot.messages[0]
        await #expect(throws: MailFailure.notFound) { try await repo.message(id: message.id, in: restricted) }
        await #expect(throws: MailFailure.notFound) { try await repo.text(for: message.id, scope: restricted) }
        await #expect(throws: MailFailure.notFound) { try await repo.thread(id: message.threadID!, page: PageRequest(), in: restricted) }
        let results = try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: restricted)
        #expect(results.items.allSatisfy { $0.accountID == data.snapshot.accounts[1].id })
    }
    @Test func emptyAccessScopesExposeNothing() async throws {
        let data = try SyntheticFixtures.make(), repo = data.repository()
        let none = AccessScope(accountIDs: [])
        #expect(try await repo.accounts(in: none).isEmpty)
        #expect(try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: none).items.isEmpty)
        let noFolders = AccessScope(accountIDs: data.scope.accountIDs, folderIDs: [])
        #expect(try await repo.messages(filter: MessageFilter(), page: PageRequest(), in: noFolders).items.isEmpty)
        await #expect(throws: MailFailure.notFound) { try await repo.text(for: data.snapshot.messages[0].id, scope: noFolders) }
    }
    @Test func stablePaginationHasNoGapsOrDuplicates() async throws {
        let data = try SyntheticFixtures.make(), repo = data.repository()
        var ids: [MessageID] = [], cursor: String?
        repeat {
            let page = try await repo.messages(filter: MessageFilter(), page: PageRequest(limit: 3, cursor: cursor), in: data.scope)
            ids += page.items.map(\.id); cursor = page.nextCursor
        } while cursor != nil
        #expect(Set(ids).count == 10)
        #expect(ids.count == 10)
        #expect(ids == data.snapshot.messages.map(\.id))
    }
    @Test(arguments: [-1, 0, 101, Int.max]) func pageLimitsAreEnforced(limit: Int) {
        #expect(throws: MailFailure.invalidInput) { try PageRequest(limit: limit) }
    }
    @Test(arguments: ["-1", "not-a-cursor", "999999999999999999999999999", "50"])
    func invalidCursorRejected(cursor: String) async throws {
        let data = try SyntheticFixtures.make(), repo = data.repository()
        await #expect(throws: MailFailure.invalidInput) {
            try await repo.messages(filter: MessageFilter(), page: PageRequest(cursor: cursor), in: data.scope)
        }
    }
    @Test func searchHandlesUmlautsAndExcludesBodyText() async throws {
        let data = try SyntheticFixtures.make(), repo = data.repository()
        var query = MessageFilter(); query.text = "ruckmeldungen"
        let result = try await repo.messages(filter: query, page: PageRequest(), in: data.scope)
        #expect(result.items.count == 1)
        #expect(result.coverage.metadataOnly)
        query.text = "Grammatur" // preview only, deliberately outside search metadata
        #expect(try await repo.messages(filter: query, page: PageRequest(), in: data.scope).items.isEmpty)
        query.text = "Donnerstag" // body only
        #expect(try await repo.messages(filter: query, page: PageRequest(), in: data.scope).items.isEmpty)
        query.text = "Materialstudie.pdf"
        #expect(try await repo.messages(filter: query, page: PageRequest(), in: data.scope).items.count == 1)
    }
    @Test func readOnlyServiceDoesNotChangeUnreadState() async throws {
        let data = try SyntheticFixtures.make(), repo = data.repository()
        let service = InboxService(repository: repo), id = data.snapshot.messages[0].id
        #expect(try await service.getEmail(id, scope: data.scope).isUnread)
        _ = try await repo.text(for: id, scope: data.scope)
        #expect(try await service.getEmail(id, scope: data.scope).isUnread)
    }
    @Test func foldersAndFlagsFilterCorrectly() async throws {
        let data = try SyntheticFixtures.make(), repo = data.repository()
        var filter = MessageFilter(); filter.role = .sent
        #expect(try await repo.messages(filter: filter, page: PageRequest(), in: data.scope).items.count == 1)
        filter.role = .inbox; filter.unreadOnly = true
        #expect(try await repo.messages(filter: filter, page: PageRequest(), in: data.scope).items.count == 4)
        filter.unreadOnly = false; filter.flaggedOnly = true
        #expect(try await repo.messages(filter: filter, page: PageRequest(), in: data.scope).items.count == 2)
    }
}
