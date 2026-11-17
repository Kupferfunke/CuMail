import Foundation
import MailDomain

public protocol ReadOnlyMailService: Sendable {
    func search(_ query: MessageFilter, page: PageRequest, scope: AccessScope) async throws -> MessagePage
    func getEmail(_ id: MessageID, scope: AccessScope) async throws -> MailMessage
    func getThread(_ id: ThreadID, page: PageRequest, scope: AccessScope) async throws -> MessagePage
}

/// Receives only a read repository, never credentials, transports or a write provider.
public struct InboxService: ReadOnlyMailService, Sendable {
    private let repository: any MailMetadataRepository
    public init(repository: any MailMetadataRepository) { self.repository = repository }

    public func accounts(scope: AccessScope) async throws -> [MailAccount] { try await repository.accounts(in: scope) }
    public func folders(scope: AccessScope) async throws -> [MailFolder] { try await repository.folders(in: scope) }
    public func search(_ query: MessageFilter, page: PageRequest, scope: AccessScope) async throws -> MessagePage {
        try await MailSearchService(repository: repository).search(query, page: page, scope: scope)
    }
    public func getEmail(_ id: MessageID, scope: AccessScope) async throws -> MailMessage {
        try await repository.message(id: id, in: scope)
    }
    public func getThread(_ id: ThreadID, page: PageRequest, scope: AccessScope) async throws -> MessagePage {
        try await repository.thread(id: id, page: page, in: scope)
    }
}

/// Content is fetched separately from metadata. The phase-0 implementation serves bundled fiction only.
public protocol PlainTextContentSource: Sendable {
    func text(for message: MessageID, scope: AccessScope) async throws -> String
}
