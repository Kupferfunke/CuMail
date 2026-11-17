import Foundation

public enum StorageClass: CaseIterable, Sendable {
    case accountConfiguration, messageMetadata, attachmentMetadata, extractedText
    case originalMIME, htmlBody, attachmentBytes, credential, ownDraft
}
public enum StorageLocation: Sendable { case index, memory, temporaryFile, keychain, draftStore }

public struct StoragePolicy: Sendable {
    public let extractedTextLimit = 256 * 1024
    public let accountTextBudget = 250 * 1024 * 1024
    public let temporaryBudget = 250 * 1024 * 1024
    public let inactiveLifetime: TimeInterval = 24 * 60 * 60
    public init() {}

    public func permits(_ data: StorageClass, at location: StorageLocation, textIndexEnabled: Bool = false) -> Bool {
        switch (data, location) {
        case (.accountConfiguration, .index), (.messageMetadata, .index), (.attachmentMetadata, .index): true
        case (.extractedText, .index): textIndexEnabled
        case (.credential, .keychain), (.credential, .memory): true
        case (.ownDraft, .draftStore), (.ownDraft, .memory): true
        case (.originalMIME, .memory), (.htmlBody, .memory), (.attachmentBytes, .memory), (.extractedText, .memory): true
        case (.attachmentBytes, .temporaryFile): true
        default: false
        }
    }

    public func mayIndexText(byteCount: Int, currentAccountBytes: Int, enabled: Bool) -> Bool {
        enabled && byteCount >= 0 && byteCount <= extractedTextLimit && currentAccountBytes >= 0
            && currentAccountBytes <= accountTextBudget && byteCount <= accountTextBudget - currentAccountBytes
    }

    /// Shared policy; ManagedTemporaryStore enforces this for app-owned files.
    public func shouldRemoveTemporary(lastUsed: Date, now: Date, isActive: Bool, isUserExport: Bool) -> Bool {
        !isActive && !isUserExport && now.timeIntervalSince(lastUsed) >= inactiveLifetime
    }
}
