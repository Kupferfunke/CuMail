import Foundation
import MailApplication
import MailDomain

public struct AssistantMailActions: Sendable {
    public typealias Submit = @Sendable (MailActionRequest, AccessScope, @escaping MailActions.Authorize) async throws -> MailActionReceipt
    public typealias Read = @Sendable (UUID, AccountID, AccessScope) async throws -> MailActionReceipt
    public typealias Undo = @Sendable (UUID, AccountID, UUID, AccessScope, @escaping MailActions.Authorize) async throws -> MailActionReceipt
    public let submit: Submit
    public let read: Read
    public let undo: Undo
    public let supportsDurableQueue: Bool
    public init(submit: @escaping Submit, read: @escaping Read, undo: @escaping Undo, supportsDurableQueue: Bool = false) {
        self.submit = submit; self.read = read; self.undo = undo; self.supportsDurableQueue = supportsDurableQueue
    }
}
