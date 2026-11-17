import Foundation
import Darwin
import Testing
import MailApplication
import MailDemo
@testable import MailMCP

private final class TestSocket {
    let fd: Int32
    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalMCPFailure.unavailable }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { p in withUnsafeMutablePointer(to: &address.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, p, 104) } } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw LocalMCPFailure.unavailable }
        var one: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { Darwin.close(fd) }
    func send(_ text: String) throws {
        let bytes = Array(text.utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
        guard count == bytes.count else { throw LocalMCPFailure.unavailable }
    }
    func line() throws -> String {
        var bytes: [UInt8] = []; let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline, bytes.count < 512 * 1024 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) <= 0 { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return String(decoding: bytes, as: UTF8.self) }
            guard count == 1 else { throw LocalMCPFailure.unavailable }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }; bytes.append(byte)
        }
        throw LocalMCPFailure.unavailable
    }
}

struct LocalMCPHostTests {
    private func setup() throws -> (URL, AssistantGateway, LocalMCPHost) {
        let directory = URL(fileURLWithPath: "/tmp/mmh-test-\(UUID().uuidString)", isDirectory: true)
        let data = try SyntheticFixtures.make(), repository = data.repository()
        let gateway = AssistantGateway(service: InboxService(repository: repository)) { id, scope in try await repository.text(for: id, scope: scope) }
        return (directory, gateway, LocalMCPHost(gateway: gateway))
    }
    @Test func privateSocketSpeaksMCPAndStopsWithoutLeavingAnEndpoint() async throws {
        let (directory, _, host) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        try await host.start(directory: directory)
        let socket = directory.appendingPathComponent("mail.sock").path
        var info = stat(); #expect(lstat(socket, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let client = try TestSocket(path: socket)
        // Modern ChatGPT probes before initialize. The legacy SDK otherwise
        // drops this request and discovery times out before fallback can run.
        try client.send("{\"jsonrpc\":\"2.0\",\"id\":\"probe\",\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n")
        let fallback = try #require(try JSONSerialization.jsonObject(with: Data(client.line().utf8)) as? [String: Any])
        #expect(fallback["id"] as? String == "probe")
        #expect((fallback["error"] as? [String: Any])?["code"] as? Int == -32601)
        try client.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"experimental\":{\"synthetic-example\":{\"enabled\":true}}},\"clientInfo\":{\"name\":\"synthetic test\",\"version\":\"1\"}}}\n")
        let response = try client.line(); #expect(response.contains("CuMail") && response.contains("protocolVersion"))
        try client.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
        // Tunnel discovery and subsequent chat calls can initialize again on
        // the same child. Preserve strict first initialization, then allow an
        // equivalent handshake with a fresh request ID and display identity.
        try client.send("{\"jsonrpc\":\"2.0\",\"id\":\"second-session\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"second synthetic client\",\"version\":\"2\"}}}\n")
        let repeated = try #require(try JSONSerialization.jsonObject(with: Data(client.line().utf8)) as? [String: Any])
        #expect(repeated["id"] as? String == "second-session" && repeated["result"] != nil)
        try client.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"mail_status\",\"arguments\":{}}}\n")
        #expect(try client.line().contains("access_not_granted_or_revoked"))
        await host.stop(); #expect(!FileManager.default.fileExists(atPath: socket))
        #expect(try client.line().isEmpty)
        try await host.start(directory: directory); await host.stop()
    }
    @Test func rejectsSharedDirectoriesLiveSiblingsOversizeFramesAndBatches() async throws {
        let (directory, gateway, host) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = chmod(directory.path, 0o755)
        await #expect(throws: (any Error).self) { try await host.start(directory: directory) }
        _ = chmod(directory.path, 0o700); try await host.start(directory: directory)
        let sibling = LocalMCPHost(gateway: gateway)
        await #expect(throws: (any Error).self) { try await sibling.start(directory: directory) }
        let socket = directory.appendingPathComponent("mail.sock").path
        let batch = try TestSocket(path: socket); try batch.send("[]\n"); #expect(try batch.line().isEmpty)
        let large = try TestSocket(path: socket); try large.send("{" + String(repeating: "x", count: 32769)); #expect(try large.line().isEmpty)
        await host.stop()
    }
    @Test func stoppingAnInFlightStartCannotLeaveAListenerBehind() async throws {
        let (directory, _, host) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let starting = Task { try? await host.start(directory: directory) }
        await Task.yield(); await host.stop(); await starting.value; await host.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mail.sock").path))
        try await host.start(directory: directory); await host.stop()
    }
    @Test func peerDisconnectAndStopDrainCleanupBeforeRestart() async throws {
        let (directory, _, host) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<8 {
            try await host.start(directory: directory)
            let client = try TestSocket(path: directory.appendingPathComponent("mail.sock").path)
            try client.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n")
            #expect(try client.line().contains("result"))
            _ = shutdown(client.fd, SHUT_RDWR)
            await host.stop()
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("mail.sock").path))
        }
    }
}
