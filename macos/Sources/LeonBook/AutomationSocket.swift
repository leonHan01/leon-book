import CryptoKit
import Darwin
import Foundation

/// Same-user Unix socket, no TCP listener and no token in command history.
/// One length-prefixed JSON request and response per connection (8 MiB each).
public enum AutomationSocket {
    public static let maximumMessageBytes = 8 * 1024 * 1024

    public static func path(for root: URL) -> String {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(canonical.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "/tmp/leonbook-api-\(getuid())/\(hash).sock"
    }

    /// nil means no listener was present BEFORE sending. Once connected, any
    /// failure is reported; writes are never replayed against the offline store.
    public static func call(_ request: AutomationRequest, root: URL) throws -> AutomationResponse? {
        // Validate the complete encoded envelope before connecting or permitting
        // offline fallback. --json and --body-file share this one size budget.
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumMessageBytes else {
            throw AutomationFailure("message_too_large", "Encoded request exceeds 8 MiB, including metadata and JSON escaping; shorten the content or split independent operations.")
        }
        let fd = try descriptor()
        defer { Darwin.close(fd) }
        var address = try address(path(for: root))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if status != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { return nil }
            throw failure("Cannot connect to app")
        }
        try verifyPeer(fd)
        try write(data, to: fd)
        return try JSONDecoder().decode(AutomationResponse.self, from: read(from: fd))
    }

    static func descriptor() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("Cannot create socket") }
        var one: Int32 = 1
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw AutomationFailure("transport_error", "Socket path is too long") }
        withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes) }
        return value
    }

    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AutomationFailure("access_denied", "Socket peer is not the current macOS user") }
    }

    static func read(from fd: Int32) throws -> Data {
        let header = try readExactly(4, from: fd)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumMessageBytes else { throw AutomationFailure("message_too_large", "JSON frame must be 1...8 MiB") }
        return try readExactly(count, from: fd)
    }

    private static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count), received = 0
        while received < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: received), count - received) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw failure("Connection ended or timed out; do not automatically retry a write") }
            received += n
        }
        return data
    }

    static func write(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumMessageBytes else { throw AutomationFailure("message_too_large", "Response exceeds 8 MiB; request a smaller page") }
        var count = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(data)
        var sent = 0
        while sent < frame.count {
            let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), frame.count - sent) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw failure("Cannot send JSON frame; outcome may be unknown") }
            sent += n
        }
    }

    static func failure(_ message: String) -> AutomationFailure {
        .init("transport_error", "\(message): \(String(cString: strerror(errno)))")
    }
}

final class AutomationSocketServer {
    let service: AutomationService
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "leonbook.automation.connections")
    private let socketPath: String
    private let lease: ExclusiveDirectoryLock

    init(root: URL, service: AutomationService) throws {
        self.service = service
        socketPath = AutomationSocket.path(for: root)
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw AutomationSocket.failure("Cannot create socket directory") }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o077 == 0 else {
            throw AutomationFailure("access_denied", "Socket directory must be owned by this user with mode 0700")
        }
        // A separate per-root lease protects stale-socket cleanup across processes.
        let leaseDirectory = directory.appendingPathComponent(URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent)
        lease = try ExclusiveDirectoryLock(directory: leaseDirectory)
        let fd = try AutomationSocket.descriptor()
        do {
            unlink(socketPath)
            var address = try AutomationSocket.address(socketPath)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { throw AutomationSocket.failure("Cannot listen for automation") }
        } catch { Darwin.close(fd); throw error }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        let path = socketPath
        source.setCancelHandler { Darwin.close(fd); unlink(path) }
        source.resume()
    }

    deinit { source.cancel() }

    private func accept(_ listener: Int32) {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 60, tv_usec: 0), one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        do {
            try AutomationSocket.verifyPeer(client)
            let request: AutomationRequest
            do { request = try JSONDecoder().decode(AutomationRequest.self, from: AutomationSocket.read(from: client)) }
            catch { throw AutomationFailure("invalid_request", error.localizedDescription) }
            // Only this background queue blocks; all app/store actor work remains async.
            let done = DispatchSemaphore(value: 0)
            Task {
                let response = await service.handle(request)
                do { try AutomationSocket.write(JSONEncoder().encode(response), to: client) }
                catch { try? AutomationSocket.write(JSONEncoder().encode(AutomationResponse(id: request.id, error: AutomationService.failure(error))), to: client) }
                done.signal()
            }
            done.wait()
        } catch {
            try? AutomationSocket.write(JSONEncoder().encode(AutomationResponse(error: AutomationService.failure(error))), to: client)
        }
    }
}

@MainActor
enum NativeAutomationServers {
    private static var servers: [String: AutomationSocketServer] = [:]
    private static var startingRoots = Set<String>()

    static func start(root: URL) async throws {
        guard ProcessInfo.processInfo.environment["LEON_BOOK_AUTOMATION"] != "0" else { return }
        for path in Array(servers.keys) where NativeWorkspaceWindows.matching(URL(fileURLWithPath: path)).isEmpty {
            servers.removeValue(forKey: path)
        }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard servers[canonical.path] == nil, startingRoots.insert(canonical.path).inserted else { return }
        defer { startingRoots.remove(canonical.path) }
        let service = AutomationService(rootURL: canonical)
        await service.setMutationHandler { workspace in
            await NativeWorkspaceWindows.reloadAfterAutomation(in: workspace, dataRoot: canonical)
        }
        servers[canonical.path] = try AutomationSocketServer(root: canonical, service: service)
    }
}
