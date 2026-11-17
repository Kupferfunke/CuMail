import Foundation
import Observation
import MailApplication
import MailDomain

struct AssistantTunnelSettings: Codable, Equatable {
    var enabled = false
    var tunnelID = ""
}

/// Owns only the outbound OpenAI transport. Provider secrets never enter it.
/// The runtime key uses a separate Keychain namespace through the frozen helper.
@MainActor @Observable final class AssistantTunnelController {
    private(set) var settings = AssistantTunnelSettings()
    private(set) var status = "ChatGPT-Verbindung ist aus."
    private(set) var ready = false
    private(set) var busy = false
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let helpers: URL
    @ObservationIgnored private var credentials: (any CredentialStore)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    // The unchanged XPC protocol supports these three secret slots. A dedicated
    // namespace and reserved ID isolate this API key from every mail account.
    static let reference = CredentialReference(accountID: try! AccountID(string: "edfc5b8c-c8ac-47a3-963f-2427cbb6c901"), purpose: .incomingPassword)
    init(defaults: UserDefaults?, directory: URL, helpersDirectory: URL? = nil) {
        self.defaults = defaults; self.directory = directory
        self.helpers = helpersDirectory ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        if let data = defaults?.data(forKey: "assistantTunnel.v1"), data.count < 2048,
           let value = try? JSONDecoder().decode(AssistantTunnelSettings.self, from: data),
           value.tunnelID.isEmpty || Self.validID(value.tunnelID) { settings = value }
    }
    func configure(credentials: any CredentialStore) { self.credentials = credentials }
    static func validID(_ value: String) -> Bool {
        value.range(of: "\\Atunnel_(?:[a-z0-9]{4}_)?[a-z0-9]{32}\\z", options: .regularExpression) != nil
    }
    private func save() { if let data = try? JSONEncoder().encode(settings) { defaults?.set(data, forKey: "assistantTunnel.v1") } }
    @discardableResult func saveConfiguration(tunnelID: String, key: String) async -> Bool {
        guard !busy, let credentials, Self.validID(tunnelID),
              key.hasPrefix("sk-"), (20...1024).contains(key.utf8.count),
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) })
        else { status = "Bitte eine gültige Tunnel-ID und einen eingeschränkten OpenAI-Schlüssel eingeben."; return false }
        busy = true; defer { busy = false }
        await stop()
        do {
            try await credentials.save(Data(key.utf8), for: Self.reference)
            settings.tunnelID = tunnelID; settings.enabled = false; save()
            status = "Verbindung gespeichert. Der Schlüssel liegt geschützt im Schlüsselbund."; return true
        } catch { status = "Der Schlüssel konnte nicht gespeichert werden. Es wurde keine Verbindung gestartet."; return false }
    }
    func setEnabled(_ enabled: Bool, localReady: Bool) async {
        guard !busy else { return }; settings.enabled = enabled; save()
        await reconcile(localReady: localReady)
    }
    func revoke() async { settings.enabled = false; save(); await stop() }
    func forget() async {
        await revoke()
        do { try await credentials?.delete(Self.reference); settings = AssistantTunnelSettings(); save(); status = "ChatGPT-Verbindung und Schlüssel entfernt." }
        catch { status = "Verbindung ist aus; der Schlüssel konnte noch nicht entfernt werden." }
    }
    func reconcile(localReady: Bool) async {
        guard settings.enabled, localReady else {
            await stop()
            if settings.enabled { status = "Wartet auf einen freigegebenen lokalen Ordner." }; return
        }
        guard process == nil, !busy else { return }
        guard Self.validID(settings.tunnelID), let credentials else { status = "Zuerst Tunnel-ID und Schlüssel speichern."; return }
        busy = true; defer { busy = false }
        let token = UUID(); generation = token
        do {
            guard let bytes = try await credentials.read(Self.reference), let key = String(data: bytes, encoding: .utf8) else { throw MailFailure.permissionDenied }
            guard generation == token, settings.enabled else { return }
            let runtime = helpers.appendingPathComponent("tunnel-client")
            let bridge = helpers.appendingPathComponent("MikeMailBridgeSandboxed")
            guard FileManager.default.isExecutableFile(atPath: runtime.path), FileManager.default.isExecutableFile(atPath: bridge.path) else { throw MailFailure.offline }
            let health = directory.appendingPathComponent("health.sock")
            let healthURL = directory.appendingPathComponent("health.url")
            try? FileManager.default.removeItem(at: healthURL)
            let child = Process(); child.executableURL = runtime
            let command = ["/usr/bin/env", "-u", "CONTROL_PLANE_API_KEY", bridge.path, "--socket", directory.appendingPathComponent("mail.sock").path]
                .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: " ")
            child.arguments = ["run", "--control-plane.tunnel-id", settings.tunnelID,
                "--mcp.command", command,
                "--mcp.max-concurrent-requests", "2", "--mcp.stdio-failure-policy", "exit",
                "--mcp.stdio-send-initialized-notification", "--health.unix-socket", health.path,
                "--health.url-file", healthURL.path, "--log.format", "json", "--log.level", "warn", "--admin-ui.log-buffer-events", "1"]
            // No inherited API keys, proxy hooks or raw logging flags.
            child.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin", "TMPDIR": directory.path, "CONTROL_PLANE_API_KEY": key]
            child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] finished in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.process = nil; self.ready = false; self.monitoring?.cancel()
                self.status = "ChatGPT-Verbindung beendet (Status \(finished.terminationStatus)). Verbindung prüfen und erneut einschalten."
            } }
            // Foundation freezes launch settings once run() succeeds. Clearing
            // environment afterwards raises an Objective-C exception. The key
            // remains private to this Process and is released with it on stop.
            try child.run(); process = child
            status = "Verbindung zu OpenAI wird geprüft …"
            monitoring = Task { [weak self] in
                var checks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(checks < 6 ? 5 : 15)); checks += 1
                    guard !Task.isCancelled, let self, self.generation == token, child.isRunning else { return }
                    let healthy = await Self.probe(runtime: runtime, urlFile: healthURL)
                    guard self.generation == token else { return }
                    self.ready = healthy
                    if healthy { self.status = "OpenAI-Verbindung bereit. Wähle CuMail in ChatGPT aus." }
                    else if checks > 6 {
                        self.status = "OpenAI-Verbindung derzeit nicht bereit. Internetverbindung, Tunnel-ID und Berechtigungen des Schlüssels prüfen."
                    }
                }
            }
        } catch {
            guard generation == token else { return }
            ready = false; status = "Verbindung nicht verfügbar. Prüfe die Einrichtung und den Schlüsselbund; es wird kein Passwortdialog automatisch geöffnet."
        }
    }
    func stop() async {
        generation = UUID(); monitoring?.cancel(); monitoring = nil; ready = false
        let child = process; process = nil
        if let child, child.isRunning {
            child.terminate()
            for _ in 0..<20 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        status = "ChatGPT-Verbindung ist aus."
    }
    private nonisolated static func probe(runtime: URL, urlFile: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: urlFile.path) else { return false }
        let probe = Process(); probe.executableURL = runtime
        probe.arguments = ["health", "--url-file", urlFile.path, "--require-control-plane-poll", "--json"]
        probe.environment = ["PATH": "/usr/bin:/bin"]
        probe.standardInput = FileHandle.nullDevice; probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        for _ in 0..<30 {
            if !probe.isRunning { return probe.terminationStatus == 0 }
            if Task.isCancelled { break }; try? await Task.sleep(for: .milliseconds(100))
        }
        if probe.isRunning { probe.terminate() }; return false
    }
}

