import Foundation
import Darwin

/// One newline-delimited JSON request per connection. No network listener.
enum ControlSocket {
    static var directory: String {
        ProcessInfo.processInfo.environment["LINK2DOWNLOAD_CONTROL_DIRECTORY"]
            ?? "/tmp/link2download-\(getuid())"
    }
    static var path: String { directory + "/control.sock" }

    static func prepareDirectory() throws {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw ControlError("IPC_UNAVAILABLE", "Cannot create the local control directory.")
        }
        var info = stat()
        guard lstat(directory, &info) == 0,
              info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_mode & 0o077 == 0 else {
            throw ControlError("IPC_UNSAFE", "The control directory must belong to this user, be a real directory, and have mode 0700.")
        }
    }

    static func address() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlError("IPC_UNAVAILABLE", "Control socket path is too long.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.copyBytes(from: bytes)
        }
        return address
    }

    static func descriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("IPC_UNAVAILABLE", "Cannot create local socket.") }
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        return fd
    }

    static func verifyPeer(_ fd: Int32) throws {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw ControlError("IPC_UNAUTHORIZED", "The control peer does not belong to this user.")
        }
    }

    static func send(_ object: Any, to fd: Int32) throws {
        var data = try ControlWire.data(object)
        guard data.count < ControlWire.maxMessageBytes else {
            throw ControlError("MESSAGE_TOO_LARGE", "The control response exceeds the size limit.")
        }
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ControlError("IPC_DISCONNECTED", "The control connection closed while sending.") }
                offset += count
            }
        }
    }

    static func receive(from fd: Int32) throws -> [String: Any] {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw ControlError("IPC_DISCONNECTED", "The control connection closed or timed out. A submitted operation may still be running; query its ID or repeat with the same requestId.")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= ControlWire.maxMessageBytes else {
                throw ControlError("MESSAGE_TOO_LARGE", "Control message exceeds the size limit.")
            }
            if let end = data.firstIndex(of: 10) {
                guard let object = try JSONSerialization.jsonObject(with: data.prefix(upTo: end)) as? [String: Any] else {
                    throw ControlError("INVALID_REQUEST", "Expected a JSON object.")
                }
                return object
            }
        }
    }

    static func connectDescriptor() throws -> Int32 {
        try prepareDirectory()
        var address = try address()
        let fd = try descriptor()
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw ControlError("APP_NOT_RUNNING", "Link2Download is not listening. Launch a build with CLI support or specify --app /path/Link2Download.app.")
        }
        do { try verifyPeer(fd) } catch { close(fd); throw error }
        return fd
    }
}

/// Acquired before settings/history initialization so a second app cannot rewrite in-flight state.
final class ControlLease {
    private let fd: Int32
    init() throws {
        try ControlSocket.prepareDirectory()
        fd = open(ControlSocket.directory + "/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ControlError("IPC_UNSAFE", "Cannot open the control owner lock.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw ControlError("IPC_UNSAFE", "Unsafe control lock file.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ControlError("APP_ALREADY_RUNNING", "Another Link2Download instance already owns the queue.")
        }
    }
    deinit { close(fd) }
}

final class ControlClient {
    private let appPath: String?
    private let autoLaunch: Bool

    init(appPath: String? = nil, autoLaunch: Bool = true) {
        self.appPath = appPath
        self.autoLaunch = autoLaunch
    }

    func call(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let fd: Int32
        do { fd = try ControlSocket.connectDescriptor() }
        catch let error as ControlError where error.code == "APP_NOT_RUNNING" && autoLaunch {
            try launch()
            let deadline = Date().addingTimeInterval(15)
            var connected: Int32?
            while Date() < deadline {
                if let value = try? ControlSocket.connectDescriptor() { connected = value; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let value = connected else {
                throw ControlError("APP_START_TIMEOUT", "Link2Download did not start its control API within 15 seconds.")
            }
            fd = value
        }
        defer { close(fd) }
        // Never reconnect/replay after sending: the operation might have been accepted.
        try ControlSocket.send(["apiVersion": ControlWire.apiVersion, "method": method, "params": params], to: fd)
        let reply = try ControlSocket.receive(from: fd)
        guard reply["apiVersion"] as? Int == ControlWire.apiVersion else {
            throw ControlError("API_VERSION_MISMATCH", "The app and helper use incompatible control API versions.")
        }
        if let error = reply["error"] as? [String: Any] {
            throw ControlError(error["code"] as? String ?? "INTERNAL_ERROR", error["message"] as? String ?? "Control operation failed.")
        }
        guard let result = reply["result"] as? [String: Any] else {
            throw ControlError("INVALID_RESPONSE", "Missing control result.")
        }
        return result
    }

    private func launch() throws {
        let application: String
        if let appPath {
            application = NSString(string: appPath).expandingTildeInPath
        } else {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            application = bundled.pathExtension == "app" ? bundled.path : "/Applications/Link2Download.app"
        }
        guard let bundle = Bundle(path: application), bundle.bundleIdentifier == "com.gzakharov.link2download" else {
            throw ControlError("APP_NOT_FOUND", "Cannot find Link2Download.app. Use --app with an absolute application path.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-a", application, "--args", "--background-control"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ControlError("APP_START_FAILED", "macOS could not launch Link2Download.") }
    }
}
