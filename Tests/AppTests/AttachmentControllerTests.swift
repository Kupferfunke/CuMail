import Foundation
import Testing
import MailDemo
import MailDomain
import MailApplication
import MailPersistence
@testable import MikeMailHub

@MainActor @Suite(.serialized)
struct AttachmentControllerTests {
    @Test func explicitPreviewKeepsLeaseThenCloseAndSelectionChangeRemoveFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentController-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ManagedTemporaryStore(root: root)
        let data = try SyntheticFixtures.make(), message = try #require(data.snapshot.messages.first { !$0.attachments.isEmpty })
        let attachment = try #require(message.attachments.first)
        let controller = AttachmentController(store: store) { _, _, _ in throw MailFailure.unsupported }
        #expect(await store.byteCount() == 0)
        controller.open(message: message, attachment: attachment, scope: data.scope, isDemo: true)
        try await ready { !controller.busy }
        let item = try #require(controller.prepared)
        #expect(item.canPreview && item.isDemo && item.lease.url.pathExtension == "pdf")
        #expect(await store.byteCount() > 0)
        controller.closePreview()
        try await ready { !controller.busy }
        #expect(!FileManager.default.fileExists(atPath: item.lease.url.path))
        #expect(await store.byteCount() == 0)
        controller.open(message: message, attachment: attachment, scope: data.scope, isDemo: true)
        try await ready { !controller.busy }
        await controller.stopAndWait()
        #expect(controller.prepared == nil)
        #expect(await store.byteCount() == 0)
    }
    @Test func cancellationAfterFirstChunkRemovesPartialAndAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentCancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ManagedTemporaryStore(root: root)
        let data = try SyntheticFixtures.make(), message = try #require(data.snapshot.messages.first { !$0.attachments.isEmpty })
        let attachment = try #require(message.attachments.first)
        let controller = AttachmentController(store: store) { _, sink, progress in
            try await sink(Data(repeating: 1, count: 65_536)); await progress(65_536, nil)
            try await Task.sleep(for: .seconds(30))
        }
        controller.open(message: message, attachment: attachment, scope: data.scope, isDemo: false)
        try await ready { controller.received == 65_536 }
        controller.cancel()
        try await ready { !controller.busy }
        #expect(!controller.failed && controller.prepared == nil)
        #expect(await store.byteCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).allSatisfy { $0.pathExtension != "partial" })
        controller.open(message: message, attachment: attachment, scope: data.scope, isDemo: true)
        try await ready { !controller.busy }
        #expect(controller.prepared != nil)
        await controller.stopAndWait()
        #expect(await store.byteCount() == 0)
    }
    private func ready(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
