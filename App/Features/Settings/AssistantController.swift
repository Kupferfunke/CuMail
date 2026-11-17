import Foundation
import Observation
import MailMCP
import MailDomain
import MailApplication

@MainActor @Observable
final class AssistantController {
    let tunnel: AssistantTunnelController
    private(set) var grant = AssistantGrant()
    private(set) var changing = false
    private(set) var running = false
    private(set) var status = "KI-Zugang ist aus."
    private(set) var accounts: [MailAccount] = []
    private(set) var folders: [MailFolder] = []
    private(set) var audit: [AssistantAuditEntry] = []
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private(set) var gateway: AssistantGateway?
    @ObservationIgnored private var host: LocalMCPHost?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var suspended = false
    init(defaults: UserDefaults?, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tmp/mmh-mcp", isDirectory: true)
        tunnel = AssistantTunnelController(defaults: defaults, directory: self.directory)
        if let data = defaults?.data(forKey: "assistantGrant.v1"), data.count <= 65536,
           let value = try? JSONDecoder().decode(AssistantGrant.self, from: data), value.accountIDs.count <= 100, value.folderIDs.count <= 1000 { grant = value }
    }
    var bridgeCommand: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MikeMailBridge").path }
    func refreshFolders(_ current: [MailFolder]) async {
        let available = Set(accounts.map(\.id))
        folders = current.filter { available.contains($0.accountID) }
        let old = grant
        grant.folderIDs.formIntersection(Set(folders.filter { grant.accountIDs.contains($0.accountID) }.map(\.id)))
        if old != grant { await apply() }
    }
    func configure(service: InboxService, accounts: [MailAccount], folders: [MailFolder], replies: AssistantReplies? = nil, actions: AssistantMailActions? = nil, readText: @escaping AssistantGateway.TextReader) async {
        self.accounts = accounts.filter { $0.provider != .microsoft }
        let available = Set(self.accounts.map(\.id))
        self.folders = folders.filter { available.contains($0.accountID) }
        let old = grant
        grant.accountIDs.formIntersection(available)
        grant.folderIDs.formIntersection(Set(self.folders.filter { grant.accountIDs.contains($0.accountID) }.map(\.id)))
        grant.replyAccountIDs.formIntersection(grant.accountIDs)
        grant.composeAccountIDs.formIntersection(grant.accountIDs)
        grant.directSendAccountIDs.formIntersection(grant.accountIDs.intersection(grant.replyAccountIDs.union(grant.composeAccountIDs)))
        grant.actionAccountIDs.formIntersection(grant.accountIDs)
        if gateway == nil {
            let gateway = AssistantGateway(service: service, replies: replies, actions: actions, textReader: readText)
            self.gateway = gateway; host = LocalMCPHost(gateway: gateway)
        }
        if !configured || old != grant {
            configured = true
            await apply()
        }
    }
    func setEnabled(_ value: Bool) async { guard !changing else { return }; grant.enabled = value; await apply() }
    func setText(_ value: Bool) async { guard !changing else { return }; grant.allowText = value; await apply() }
    func setReplies(_ account: AccountID, allowed: Bool) async {
        guard !changing, grant.accountIDs.contains(account) else { return }
        if allowed { grant.replyAccountIDs.insert(account) } else { grant.replyAccountIDs.remove(account) }
        if !allowed && !grant.composeAccountIDs.contains(account) { grant.directSendAccountIDs.remove(account) }
        await apply()
    }
    func setActions(_ account: AccountID, allowed: Bool) async {
        guard !changing, grant.accountIDs.contains(account) else { return }
        if allowed { grant.actionAccountIDs.insert(account) } else { grant.actionAccountIDs.remove(account) }
        await apply()
    }
    func setCompose(_ account: AccountID, allowed: Bool) async {
        guard !changing, grant.accountIDs.contains(account) else { return }
        if allowed { grant.composeAccountIDs.insert(account) } else { grant.composeAccountIDs.remove(account) }
        if !allowed && !grant.replyAccountIDs.contains(account) { grant.directSendAccountIDs.remove(account) }
        await apply()
    }
    func setDirectSend(_ account: AccountID, allowed: Bool) async {
        guard !changing, grant.accountIDs.contains(account),
              grant.replyAccountIDs.contains(account) || grant.composeAccountIDs.contains(account) else { return }
        if allowed { grant.directSendAccountIDs.insert(account) } else { grant.directSendAccountIDs.remove(account) }
        await apply()
    }
    func setFolder(_ folder: MailFolder, allowed: Bool) async {
        guard !changing, folders.contains(where: { $0.id == folder.id }) else { return }
        if allowed { grant.accountIDs.insert(folder.accountID); grant.folderIDs.insert(folder.id) }
        else {
            grant.folderIDs.remove(folder.id)
            if !folders.contains(where: { $0.accountID == folder.accountID && grant.folderIDs.contains($0.id) }) {
                grant.accountIDs.remove(folder.accountID); grant.replyAccountIDs.remove(folder.accountID); grant.actionAccountIDs.remove(folder.accountID); grant.composeAccountIDs.remove(folder.accountID); grant.directSendAccountIDs.remove(folder.accountID)
            }
        }
        await apply()
    }
    func setAccountFolders(_ account: AccountID, allowed: Bool) async {
        guard !changing, accounts.contains(where: { $0.id == account }) else { return }
        let selected = Set(folders.filter { $0.accountID == account }.map(\.id))
        guard !selected.isEmpty else { return }
        if allowed {
            guard grant.folderIDs.union(selected).count <= 1000 else {
                status = "Es sind zu viele Ordner für eine einzelne Freigabe ausgewählt."; return
            }
            grant.accountIDs.insert(account); grant.folderIDs.formUnion(selected)
        } else {
            grant.folderIDs.subtract(selected); grant.accountIDs.remove(account); grant.replyAccountIDs.remove(account); grant.actionAccountIDs.remove(account); grant.composeAccountIDs.remove(account); grant.directSendAccountIDs.remove(account)
        }
        await apply()
    }
    func revoke() async {
        grant = AssistantGrant()
        // Revocation is never gated on an in-flight UI operation.
        await gateway?.setGrant(grant)
        await tunnel.revoke()
        await host?.stop(); running = false; save(); status = "KI-Zugang widerrufen. Alle Freigaben sind entfernt."
    }
    func suspend() async {
        suspended = true
        await gateway?.setGrant(AssistantGrant())
        await tunnel.stop()
        await host?.stop(); running = false
    }
    func resume() async { suspended = false; await apply() }
    func actionAuthorization(account: AccountID, scope: AccessScope) throws -> AssistantActionAuthorization {
        guard configured, !suspended, grant.enabled, grant.accountIDs.contains(account),
              grant.actionAccountIDs.contains(account), scope.accountIDs.contains(account),
              let current = grant.actionAuthorizations[account] else { throw MailFailure.permissionDenied }
        return AssistantActionAuthorization(generation: current.generation,
            folderIDs: current.folderIDs.intersection(scope.folderIDs ?? current.folderIDs))
    }
    func authorizeQueuedAction(_ receipt: MailActionReceipt) throws {
        // A normal shutdown/maintenance is not a revocation. Preserve waiting
        // work while the host is temporarily suspended.
        if suspended { throw CancellationError() }
        let current = try actionAuthorization(account: receipt.request.accountID, scope: grant.scope)
        guard let saved = receipt.assistantAuthorization, saved.generation == current.generation,
              saved.folderIDs.isSubset(of: current.folderIDs), receipt.permitted(in: grant.scope),
              receipt.permitted(in: saved.scope(account: receipt.request.accountID)) else { throw MailFailure.permissionDenied }
    }
    func refreshAudit() async { audit = await gateway?.recentAudit() ?? [] }
    private func save() { if let data = try? JSONEncoder().encode(grant) { defaults?.set(data, forKey: "assistantGrant.v1") } }
    private func apply() async {
        changing = true; defer { changing = false }
        grant.reconcileActionAuthorizations(folders: folders)
        save()
        guard let gateway, let host else { status = "Wartet auf den geöffneten lokalen Index."; return }
        let selected = grant
        await gateway.setGrant(suspended ? AssistantGrant() : selected)
        await tunnel.stop()
        await host.disconnectClients()
        guard !suspended, selected.enabled, !selected.accountIDs.isEmpty, !selected.folderIDs.isEmpty else {
            await host.stop(); running = false
            status = selected.enabled ? "Wähle mindestens einen Ordner für den Zugriff." : "KI-Zugang ist aus."
            return
        }
        do {
            try await host.start(directory: directory)
            guard !suspended, grant == selected else { await host.stop(); return }
            running = true
            status = "Lokaler KI-Zugang bereit. Die Verbindung zu ChatGPT wird separat eingerichtet."
            await tunnel.reconcile(localReady: true)
        } catch {
            running = false; await gateway.setGrant(AssistantGrant())
            status = "Lokaler Lesezugang konnte nicht gestartet werden. Beende weitere Instanzen der App und versuche es erneut."
        }
    }
}
