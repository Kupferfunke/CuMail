import Foundation
import Darwin

// Byte-only stdio adapter. It has no database, mail-provider or Keychain code.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
let defaultSocket = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Containers/ch.kupferfunke.MikeMailHub/Data/tmp/mmh-mcp/mail.sock").path
let path: String
if args.isEmpty { path = defaultSocket }
else if args.count == 2, args[0] == "--socket", args[1].hasPrefix("/") { path = args[1] }
else { fail("Usage: MikeMailBridge [--socket /absolute/private/socket]") }
guard path.utf8.count < 104 else { fail("Mail bridge socket path is too long.") }
var parent = stat(), target = stat()
let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
guard lstat(directory, &parent) == 0, parent.st_uid == geteuid(), parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o077 == 0,
      lstat(path, &target) == 0, target.st_uid == geteuid(), target.st_mode & S_IFMT == S_IFSOCK, target.st_mode & 0o077 == 0
else { fail("Open Mike Mail Hub and explicitly enable the assistant access first.") }
let connection = socket(AF_UNIX, SOCK_STREAM, 0)
guard connection >= 0 else { fail("Mail bridge unavailable.") }
var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, source, 104) } } }
let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard connected == 0 else { fail("Mike Mail Hub is unavailable or assistant access is disabled.") }
var peerUser: uid_t = 0, peerGroup: gid_t = 0
guard getpeereid(connection, &peerUser, &peerGroup) == 0, peerUser == geteuid() else { fail("Unexpected local mail service owner.") }
signal(SIGPIPE, SIG_IGN)
for fd in [STDIN_FILENO, STDOUT_FILENO, connection] {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { fail("Could not configure mail bridge pipes.") }
}
func forward(_ bytes: [UInt8], count: Int, to fd: Int32) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5)); var offset = 0
    while offset < count {
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
        if written > 0 { offset += written; continue }
        if written < 0 && errno == EINTR { continue }
        guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK, ContinuousClock.now < deadline else { return false }
        var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&writable, 1, 100)
    }
    return true
}
var inputOpen = true
var buffer = [UInt8](repeating: 0, count: 16384)
while true {
    var descriptors = [pollfd(fd: inputOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0), pollfd(fd: connection, events: Int16(POLLIN), revents: 0)]
    let ready = poll(&descriptors, 2, -1)
    if ready < 0 { if errno == EINTR { continue }; break }
    for i in 0..<2 where descriptors[i].revents != 0 {
        let count = Darwin.read(descriptors[i].fd, &buffer, buffer.count)
        if count > 0 {
            guard forward(buffer, count: count, to: i == 0 ? connection : STDOUT_FILENO) else { Darwin.close(connection); exit(1) }
        } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
            if i == 0 { inputOpen = false; _ = shutdown(connection, SHUT_WR) }
            else { Darwin.close(connection); exit(0) }
        }
    }
}
Darwin.close(connection)
