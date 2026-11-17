import Foundation
import Darwin
import MailApplication

/// Only called for a destination explicitly returned by NSSavePanel.
public enum AttachmentExporter {
    public static func export(source: URL, destination: URL) throws {
        guard source.isFileURL, destination.isFileURL, source.standardizedFileURL != destination.standardizedFileURL
        else { throw LocalStoreFailure.invalidInput }
        try PrivateFiles.protect(source)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?, operationError: (any Error)?
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
            do {
                try Task.checkCancellation()
                let manager = FileManager.default
                if let attributes = try? manager.attributesOfItem(atPath: target.path),
                   attributes[.type] as? FileAttributeType != .typeRegular { throw LocalStoreFailure.invalidInput }
                let folder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                defer { try? manager.removeItem(at: folder) }
                let staging = folder.appendingPathComponent(UUID().uuidString.lowercased())
                let descriptor = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard descriptor >= 0 else { throw LocalStoreFailure.unavailable }
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? output.close() }
                let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
                var total = 0
                while let chunk = try input.read(upToCount: AttachmentRequest.chunkSize), !chunk.isEmpty {
                    try Task.checkCancellation(); total += chunk.count
                    guard total <= AttachmentRequest.byteLimit else { throw AttachmentFailure.tooLarge }
                    try output.write(contentsOf: chunk)
                }
                guard total == PrivateFiles.size(source) else { throw AttachmentFailure.changed }
                try output.synchronize(); try output.close()
                try ManagedTemporaryStore.quarantine(staging)
                try Task.checkCancellation()
                if manager.fileExists(atPath: target.path) {
                    _ = try manager.replaceItemAt(target, withItemAt: staging, options: .usingNewMetadataOnly)
                } else { try manager.moveItem(at: staging, to: target) }
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
    }
}
