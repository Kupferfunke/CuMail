import Foundation
import Testing
import MailDomain
import MailApplication
import MailDemo
import MailPersistence
@testable import MikeMailHub

@MainActor @Suite(.serialized)
struct ContentIndexTests {
    @Test func backgroundSearchWaitsForIdlePersistsProgressAndLeavesReadStatusUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CuMail-texts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try SyntheticFixtures.make(), account = data.snapshot.accounts[0].id
        let repo = try EncryptedMailRepository(paths: WorkspacePaths(root: root, cache: root.appendingPathComponent("Cache")), key: Data(repeating: 42, count: 32))
        try await repo.seedIfNeeded(data.snapshot)
        var settings = try await repo.settings(for: account)
        settings.textIndexEnabled = true; settings.fullTextIndexEnabled = true; settings.markReadAfterSeconds = 5
        try await repo.saveSettings(settings)
        let messages = data.snapshot.messages.filter { $0.accountID == account }, skipped = messages[0].id
        var idle = false, reads: [MessageID] = []
        let controller = ContentIndexController()
        controller.configure(repository: repo, mayRun: { idle }, read: { message in
            reads.append(message.id)
            if message.id == skipped { throw IMAPFailure.noPlainText }
            return MailBody(text: "<p>Shared searchable text</p>", format: .html)
        })
        controller.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.isEmpty)
        await controller.stop(); idle = true; controller.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.progress[account]?.pending != 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        await controller.stop(); await controller.refresh()
        #expect(controller.progress[account]?.indexed == messages.count - 1)
        #expect(controller.progress[account]?.skipped == 1)
        #expect(Set(reads).count == messages.count)
        for message in messages { #expect(try await repo.message(id: message.id, in: data.scope).isUnread == message.isUnread) }
        let readCount = reads.count
        controller.start(); try await Task.sleep(for: .milliseconds(200)); await controller.stop()
        #expect(reads.count == readCount)
        #expect(try await repo.settings(for: account).markReadAfterSeconds == 5)
        try await repo.close()
    }
}
