import Foundation
import Darwin
import MailDomain
import MailApplication
import MailSecurity

/// A lease keeps a displayed file out of time/budget cleanup. Exports never enter this store.
public struct TemporaryLease: Sendable {
    public let fileID: UUID
    public let url: URL
    let token: UUID
}

public struct TemporaryDownload: Sendable {
    let id: UUID
    let token: UUID
}

public actor ManagedTemporaryStore {
    private struct Entry: Codable {
        let id: UUID
        let account: String
        var lastUsed: Date
        var suffix: String? = nil
    }
    private struct Pending {
        let token: UUID
        let account: AccountID
        let handle: FileHandle
        let maximum: Int
        var written: Int = 0
    }
    private var pending: [UUID: Pending] = [:]
    private static let suffixes: Set<String> = ["cache", "pdf", "png", "jpg", "txt"]
    private let root: URL
    private let budget: Int64
    private let lifetime: TimeInterval
    private let maximumFileBytes: Int
    private var entries: [UUID: Entry]
    private var leases: [UUID: UUID] = [:]
    private var expiryTask: Task<Void, Never>?
    private var register: URL { root.appendingPathComponent("register.json") }

    public init(root: URL, budget: Int64 = 250 * 1024 * 1024,
                lifetime: TimeInterval = 24 * 60 * 60, maximumFileBytes: Int = 25 * 1024 * 1024) throws {
        guard budget > 0, budget <= 250 * 1024 * 1024, lifetime > 0, lifetime <= 24 * 60 * 60,
              maximumFileBytes > 0, maximumFileBytes <= 25 * 1024 * 1024 else { throw LocalStoreFailure.invalidInput }
        try PrivateFiles.directory(root)
        self.root = root; self.budget = budget; self.lifetime = lifetime; self.maximumFileBytes = maximumFileBytes
        let path = root.appendingPathComponent("register.json")
        if FileManager.default.fileExists(atPath: path.path) {
            try PrivateFiles.protect(path)
            guard PrivateFiles.size(path) <= 4 * 1024 * 1024 else { throw LocalStoreFailure.invalidInput }
            let records = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: path))
            guard records.count <= 10_000, Set(records.map(\.id)).count == records.count,
                  records.allSatisfy({ UUID(uuidString: $0.account) != nil && $0.lastUsed.timeIntervalSince1970.isFinite && Self.suffixes.contains($0.suffix ?? "cache") })
            else { throw LocalStoreFailure.invalidInput }
            entries = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        } else { entries = [:] }
    }

    /// Startup recovery: missing files and unregistered files left by a crash are discarded.
    public func recover(now: Date = Date()) throws {
        for id in Array(entries.keys) {
            if FileManager.default.fileExists(atPath: file(id).path) { try PrivateFiles.protect(file(id)) }
            else { entries.removeValue(forKey: id) }
        }
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard Self.suffixes.union(["partial"]).contains(url.pathExtension),
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  pending[id] == nil,
                  entries[id] == nil || url.pathExtension != (entries[id]?.suffix ?? "cache") else { continue }
            // Removing a link removes the link itself, never its target.
            try FileManager.default.removeItem(at: url)
        }
        try cleanup(now: now)
    }

    /// Files are private from the first byte; cancellation never publishes a partial file.
    public func beginDownload(account: AccountID, maximumBytes: Int, now: Date = Date()) throws -> TemporaryDownload {
        guard maximumBytes >= 0, maximumBytes <= maximumFileBytes, entries.count + pending.count < 10_000,
              now.timeIntervalSince1970.isFinite else { throw LocalStoreFailure.invalidInput }
        try PrivateFiles.directory(root)
        try cleanup(now: now, reserving: Int64(maximumBytes))
        let id = UUID(), token = UUID(), url = partial(id)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw LocalStoreFailure.unavailable }
        pending[id] = Pending(token: token, account: account, handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), maximum: maximumBytes)
        return TemporaryDownload(id: id, token: token)
    }
    public func append(_ bytes: Data, to download: TemporaryDownload) throws {
        try Task.checkCancellation()
        guard var job = pending[download.id], job.token == download.token else { throw MailFailure.notFound }
        guard bytes.count <= AttachmentRequest.chunkSize, bytes.count <= job.maximum - job.written else { throw AttachmentFailure.tooLarge }
        try job.handle.write(contentsOf: bytes)
        job.written += bytes.count; pending[download.id] = job
    }
    public func finish(_ download: TemporaryDownload, mimeType: String? = nil, now: Date = Date()) throws -> TemporaryLease {
        try Task.checkCancellation()
        guard let job = pending[download.id], job.token == download.token,
              now.timeIntervalSince1970.isFinite else { throw MailFailure.notFound }
        var destination: URL?
        do {
            try job.handle.synchronize(); try job.handle.close()
            let source = partial(download.id)
            try PrivateFiles.protect(source)
            guard PrivateFiles.size(source) == job.written else { throw AttachmentFailure.changed }
            let reader = try FileHandle(forReadingFrom: source)
            let prefix = try reader.read(upToCount: 512) ?? Data(); try reader.close()
            let suffix = mimeType.flatMap { AttachmentSafety.previewExtension(mimeType: $0, prefix: prefix) } ?? "cache"
            let url = root.appendingPathComponent(download.id.uuidString.lowercased() + "." + suffix)
            try FileManager.default.moveItem(at: source, to: url)
            destination = url
            try Self.quarantine(url)
            entries[download.id] = Entry(id: download.id, account: job.account.description, lastUsed: now, suffix: suffix)
            pending.removeValue(forKey: download.id)
            try persist()
            return try acquire(download.id, account: job.account, now: now)
        } catch {
            try? job.handle.close(); pending.removeValue(forKey: download.id); entries.removeValue(forKey: download.id)
            try? FileManager.default.removeItem(at: partial(download.id))
            if let destination { try? FileManager.default.removeItem(at: destination) }
            try? persist(); throw error
        }
    }
    public func abort(_ download: TemporaryDownload) throws {
        guard let job = pending[download.id], job.token == download.token else { return }
        try? job.handle.close()
        let url = partial(download.id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        pending.removeValue(forKey: download.id)
    }
    public func create(_ data: Data, account: AccountID, now: Date = Date()) throws -> TemporaryLease {
        let job = try beginDownload(account: account, maximumBytes: data.count, now: now)
        do {
            for offset in stride(from: 0, to: data.count, by: AttachmentRequest.chunkSize) {
                try append(data.subdata(in: offset..<min(data.count, offset + AttachmentRequest.chunkSize)), to: job)
            }
            return try finish(job, now: now)
        } catch { try? abort(job); throw error }
    }
    /// Called after preview/export; never removes a file that another lease still uses.
    public func discard(_ lease: TemporaryLease) throws {
        guard leases[lease.token] == lease.fileID else { return }
        leases.removeValue(forKey: lease.token)
        if !leases.values.contains(lease.fileID) { try remove(lease.fileID) }
        try persist()
    }
    public static func quarantine(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeOtherDownload",
            "LSQuarantineAgentName": "Mike Mail Hub", "LSQuarantineTimeStamp": Date()]
        var target = url; try target.setResourceValues(values)
    }

    public func acquire(_ id: UUID, account: AccountID, now: Date = Date()) throws -> TemporaryLease {
        guard var entry = entries[id], entry.account == account.description,
              now.timeIntervalSince1970.isFinite, FileManager.default.fileExists(atPath: file(id).path)
        else { throw MailFailure.notFound }
        try PrivateFiles.protect(file(id))
        entry.lastUsed = now; entries[id] = entry
        try persist()
        let token = UUID(); leases[token] = id
        return TemporaryLease(fileID: id, url: file(id), token: token)
    }
    public func release(_ lease: TemporaryLease, now: Date = Date()) throws {
        guard leases.removeValue(forKey: lease.token) == lease.fileID else { return }
        if var entry = entries[lease.fileID] {
            guard now.timeIntervalSince1970.isFinite else { throw LocalStoreFailure.invalidInput }
            entry.lastUsed = now; entries[lease.fileID] = entry; try persist()
        }
        try cleanup(now: now)
    }
    public func cleanup(now: Date = Date(), reserving bytes: Int64 = 0) throws {
        guard now.timeIntervalSince1970.isFinite, bytes >= 0, bytes <= budget else { throw LocalStoreFailure.budgetExceeded }
        let active = Set(leases.values)
        let ordered = entries.values.sorted { $0.lastUsed < $1.lastUsed }
        var total = committedBytes() + pending.values.reduce(Int64(0)) { $0 + Int64($1.maximum) }
        for entry in ordered where !active.contains(entry.id) {
            if now.timeIntervalSince(entry.lastUsed) >= lifetime || total > budget - bytes {
                total -= PrivateFiles.size(file(entry.id)); try remove(entry.id)
            }
        }
        try persist()
        guard total <= budget - bytes else { throw LocalStoreFailure.budgetExceeded }
    }
    public func removeAccount(_ account: AccountID) throws {
        for (id, job) in Array(pending) where job.account == account { try abort(TemporaryDownload(id: id, token: job.token)) }
        for entry in Array(entries.values) where entry.account == account.description { try remove(entry.id) }
        try persist()
    }
    public func clear() throws {
        for (id, job) in Array(pending) { try abort(TemporaryDownload(id: id, token: job.token)) }
        for id in Array(entries.keys) { try remove(id) }
        try persist()
    }
    public func byteCount() -> Int64 { committedBytes() + pending.values.reduce(Int64(0)) { $0 + Int64($1.written) } }
    private func committedBytes() -> Int64 { entries.keys.reduce(0) { $0 + PrivateFiles.size(file($1)) } }
    private func partial(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".partial") }
    private func file(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + "." + (entries[id]?.suffix ?? "cache")) }
    private func remove(_ id: UUID) throws {
        let url = file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        entries.removeValue(forKey: id)
        leases = leases.filter { $0.value != id }
    }
    private func persist() throws {
        try PrivateFiles.protect(register)
        try JSONEncoder().encode(entries.values.sorted { $0.id.uuidString < $1.id.uuidString }).write(to: register, options: .atomic)
        try PrivateFiles.protect(register)
        scheduleExpiry()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        let active = Set(leases.values)
        guard let next = entries.values.filter({ !active.contains($0.id) }).map({ $0.lastUsed.addingTimeInterval(lifetime) }).min()
        else { expiryTask = nil; return }
        let delay = max(0.05, next.timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try await self?.cleanup()
            } catch is CancellationError { }
            catch { RedactedLog.record(.operationFailed, outcome: .failed) }
        }
    }
    deinit { expiryTask?.cancel() }
}
