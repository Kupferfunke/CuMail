import Foundation
import Darwin
import MCP
import Logging
import NIOCore
import NIOPosix

public enum LocalMCPFailure: Error { case unavailable, unsafePath, capacity, frameLimit }

/// A private filesystem socket, never an IP listener. The companion process
/// forwards standard MCP stdio frames. Account data remains owned by the app.
public actor LocalMCPHost {
    private let gateway: AssistantGateway
    private var group: MultiThreadedEventLoopGroup?
    private var listener: (any Channel)?
    private var channels: [UUID: any Channel] = [:]
    private var servers: [UUID: Server] = [:]
    private var finishing: [UUID: Task<Void, Never>] = [:]
    private var epoch = UUID()
    private var path: String?
    private var starting = false
    private var stopping = 0
    public init(gateway: AssistantGateway) { self.gateway = gateway }
    public func start(directory: URL) async throws {
        guard listener == nil else { return }
        guard !starting, stopping == 0 else { throw LocalMCPFailure.unavailable }
        starting = true; defer { starting = false }
        try Self.prepareDirectory(directory)
        let socketPath = directory.appendingPathComponent("mail.sock").path
        guard socketPath.utf8.count < 104 else { throw LocalMCPFailure.unsafePath }
        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            // A live sibling process must not have its endpoint replaced.
            guard existing.st_uid == geteuid(), existing.st_mode & S_IFMT == S_IFSOCK else { throw LocalMCPFailure.unsafePath }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw LocalMCPFailure.unavailable }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { source in withUnsafeMutablePointer(to: &address.sun_path) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, source, 104) } } }
            let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let failure = errno; Darwin.close(probe)
            guard connected != 0, failure == ECONNREFUSED else { throw LocalMCPFailure.unavailable }
            guard unlink(socketPath) == 0 else { throw LocalMCPFailure.unsafePath }
        }
        let worker = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        epoch = UUID(); let generation = epoch
        do {
            let channel = try await ServerBootstrap(group: worker)
                .serverChannelOption(ChannelOptions.backlog, value: 4)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 4)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeFutureWithTask { try await self.accept(channel, generation: generation) }
                }.bind(unixDomainSocketPath: socketPath).get()
            guard generation == epoch else { try? await channel.close().get(); throw LocalMCPFailure.unavailable }
            guard chmod(socketPath, 0o600) == 0 else { try? await channel.close().get(); throw LocalMCPFailure.unsafePath }
            listener = channel; group = worker; path = socketPath
        } catch {
            // A concurrent stop must not shut down a worker whose bind has not
            // completed yet. The starting operation owns it until publication.
            epoch = UUID(); await disconnectClients()
            try? await worker.shutdownGracefully()
            var info = stat()
            if lstat(socketPath, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK { _ = unlink(socketPath) }
            throw error
        }
    }
    private static func prepareDirectory(_ url: URL) throws {
        let path = url.path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT, mkdir(path, 0o700) == 0 else { throw LocalMCPFailure.unsafePath }
            guard lstat(path, &info) == 0 else { throw LocalMCPFailure.unsafePath }
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw LocalMCPFailure.unsafePath }
    }
    private func accept(_ channel: any Channel, generation: UUID) async throws {
        guard generation == epoch, channels.count < 4 else { try? await channel.close().get(); throw LocalMCPFailure.capacity }
        let id = UUID(); channels[id] = channel
        let handshake = LegacyMCPHandshake()
        let transport = LocalChannelTransport(channel: channel, handshake: handshake)
        do {
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandlers(ByteToMessageHandler(MCPLineDecoder()), MCPInbound(continuation: transport.continuation, handshake: handshake))
            }.get()
            let server = await gateway.server()
            guard generation == epoch else { throw LocalMCPFailure.unavailable }
            servers[id] = server
            try await server.start(transport: transport)
            channel.closeFuture.whenComplete { _ in Task { await self.finished(id) } }
        } catch { await finished(id); throw error }
    }
    private func finished(_ id: UUID) async {
        if let task = finishing[id] { await task.value; return }
        let channel = channels.removeValue(forKey: id)
        let server = servers.removeValue(forKey: id)
        guard channel != nil || server != nil else { return }
        let task = Task { await server?.stop(); try? await channel?.close().get() }
        finishing[id] = task
        await task.value; finishing.removeValue(forKey: id)
    }
    public func disconnectClients() async {
        for id in Array(channels.keys) { await finished(id) }
        // closeFuture can already have started cleanup on another actor turn.
        // Drain that work before the socket's event loop is shut down.
        for task in Array(finishing.values) { await task.value }
    }
    public func stop() async {
        stopping += 1; defer { stopping -= 1 }
        epoch = UUID()
        let listening = listener; listener = nil
        let worker = group; group = nil
        let oldPath = path; path = nil
        try? await listening?.close().get()
        await disconnectClients()
        try? await worker?.shutdownGracefully()
        if let oldPath { var info = stat(); if lstat(oldPath, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK { _ = unlink(oldPath) } }
    }
}

struct MCPLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        guard let newline = view.firstIndex(of: 10) else {
            guard buffer.readableBytes <= 32768 else { throw LocalMCPFailure.frameLimit }; return .needMoreData
        }
        let length = view.distance(from: view.startIndex, to: newline)
        guard length <= 32768 else { throw LocalMCPFailure.frameLimit }
        guard let frame = buffer.readSlice(length: length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 1)
        if length > 0 {
            // SDK dispatches individual messages; refuse request batches at the
            // framing boundary to keep concurrency and parser work bounded.
            guard frame.readableBytesView.first(where: { $0 != 32 && $0 != 9 && $0 != 13 }) == 123 else { throw LocalMCPFailure.frameLimit }
            context.fireChannelRead(wrapInboundOut(frame))
        }
        return .continue
    }
}

private final class MCPInbound: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let handshake: LegacyMCPHandshake
    private var window = ContinuousClock.now
    private var count = 0
    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation, handshake: LegacyMCPHandshake) {
        self.continuation = continuation; self.handshake = handshake
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if window.duration(to: .now) > .seconds(60) { window = .now; count = 0 }
        count += 1
        guard count <= 90 else { context.close(promise: nil); return }
        var bytes = Data(unwrapInboundIn(data).readableBytesView)
        // MCP 2026 clients probe before the legacy initialize handshake. SDK
        // 0.12.1 strict mode silently drops this unknown pre-initialize method.
        // Reply explicitly so the client can negotiate our supported 2025
        // protocol. Do not relax initialization checks for any actual tools.
        if let request = try? JSONDecoder().decode(Request<DiscoveryProbe>.self, from: bytes),
           request.method == DiscoveryProbe.name {
            guard context.channel.isWritable,
                  let reply = try? JSONEncoder().encode(DiscoveryProbe.response(id: request.id,
                    error: .methodNotFound("Use the initialize handshake to negotiate the supported protocol.")))
            else { context.close(promise: nil); return }
            var output = context.channel.allocator.buffer(capacity: reply.count + 1)
            output.writeBytes(reply); output.writeInteger(UInt8(10))
            context.writeAndFlush(NIOAny(output), promise: nil)
            return
        }
        // This read-only server implements no experimental client features.
        // SDK 0.12.1 decodes that extensible object as [String: String], which
        // rejects ChatGPT's valid nested capability values. Ignore only this
        // unused capability; preserve all standard fields and tool arguments.
        if var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           object["method"] as? String == Initialize.name,
           var params = object["params"] as? [String: Any],
           var capabilities = params["capabilities"] as? [String: Any],
           capabilities.removeValue(forKey: "experimental") != nil {
            params["capabilities"] = capabilities; object["params"] = params
            guard let normalized = try? JSONSerialization.data(withJSONObject: object) else { context.close(promise: nil); return }
            bytes = normalized
        }
        if let reply = handshake.prepare(bytes) {
            guard context.channel.isWritable else { context.close(promise: nil); return }
            var output = context.channel.allocator.buffer(capacity: reply.count + 1)
            output.writeBytes(reply); output.writeInteger(UInt8(10))
            context.writeAndFlush(NIOAny(output), promise: nil)
            return
        }
        if case .dropped = continuation.yield(bytes) { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { continuation.finish(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { continuation.finish(throwing: LocalMCPFailure.unavailable); context.close(promise: nil) }
}

private enum DiscoveryProbe: MCP.Method {
    static let name = "server/discover"
}

/// ChatGPT opens successive logical sessions over one tunnel stdio child.
/// Reuse only a completed SDK handshake with the same protocol/capabilities;
/// the client display identity is not an authorization boundary. Actual tool
/// authorization always uses the current gateway grant. Other handshakes still
/// go through the strict SDK. Never cache tool results or session credentials.
private final class LegacyMCPHandshake: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Request<Initialize>?
    private var established: (Initialize.Parameters, Initialize.Result)?
    func prepare(_ data: Data) -> Data? {
        guard let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data),
              request.method == Initialize.name else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let (params, result) = established,
           params.protocolVersion == request.params.protocolVersion,
           params.capabilities == request.params.capabilities {
            return try? JSONEncoder().encode(Initialize.response(id: request.id, result: result))
        }
        if established == nil, pending == nil { pending = request }
        return nil
    }
    func observe(_ data: Data) {
        guard let response = try? JSONDecoder().decode(Response<Initialize>.self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let request = pending, request.id == response.id else { return }
        if case .success(let result) = response.result { established = (request.params, result) }
        pending = nil
    }
}

private actor LocalChannelTransport: Transport {
    nonisolated let logger = Logger(label: "MikeMailHub.MCP", factory: { _ in SwiftLogNoOpLogHandler() })
    nonisolated let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let stream: AsyncThrowingStream<Data, any Error>
    private let channel: any Channel
    private let handshake: LegacyMCPHandshake
    init(channel: any Channel, handshake: LegacyMCPHandshake) {
        self.channel = channel
        self.handshake = handshake
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(8))
    }
    func connect() async throws {}
    func receive() -> AsyncThrowingStream<Data, any Error> { stream }
    func disconnect() async { continuation.finish(); try? await channel.close().get() }
    func send(_ data: Data) async throws {
        handshake.observe(data)
        guard data.count <= 512 * 1024, channel.isActive, channel.isWritable else { throw LocalMCPFailure.unavailable }
        var buffer = channel.allocator.buffer(capacity: data.count + 1); buffer.writeBytes(data); buffer.writeInteger(UInt8(10))
        let frame = buffer
        let channel = channel
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await channel.writeAndFlush(frame).get() }
            group.addTask { try await Task.sleep(for: .seconds(5)); try? await channel.close().get(); throw LocalMCPFailure.unavailable }
            defer { group.cancelAll() }; _ = try await group.next()
        }
    }
}
