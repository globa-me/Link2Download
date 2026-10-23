import Foundation
import Darwin

final class ControlServer {
    private var listener: Int32 = -1
    private let slots = DispatchSemaphore(value: 8)
    private let handler: @MainActor (String, [String: Any]) throws -> [String: Any]

    init(handler: @escaping @MainActor (String, [String: Any]) throws -> [String: Any]) {
        self.handler = handler
    }

    func start() throws {
        var address = try ControlSocket.address()
        let fd = try ControlSocket.descriptor()
        // The caller owns ControlLease. Only that owner may remove a stale socket.
        unlink(ControlSocket.path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(ControlSocket.path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ControlError("IPC_UNAVAILABLE", "Cannot listen on the local control socket.")
        }
        listener = fd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let self, self.listener == fd {
                let peer = accept(fd, nil, nil)
                if peer < 0 { if errno == EINTR { continue }; break }
                guard self.slots.wait(timeout: .now()) == .success else { close(peer); continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { close(peer); self.slots.signal() }
                    self.configure(peer)
                    do {
                        try ControlSocket.verifyPeer(peer)
                        let request = try ControlSocket.receive(from: peer)
                        guard request["apiVersion"] as? Int == ControlWire.apiVersion else {
                            throw ControlError("API_VERSION_MISMATCH", "Unsupported control API version.")
                        }
                        guard let method = request["method"] as? String,
                              let params = request["params"] as? [String: Any] else {
                            throw ControlError("INVALID_REQUEST", "Expected method and params object.")
                        }
                        let completion = DispatchSemaphore(value: 0)
                        Task { @MainActor in
                            let response: [String: Any]
                            do {
                                response = ["apiVersion": ControlWire.apiVersion, "result": try self.handler(method, params)]
                            } catch {
                                let failure = error as? ControlError ?? ControlError("INTERNAL_ERROR", error.localizedDescription)
                                response = ["apiVersion": ControlWire.apiVersion, "error": failure.object]
                            }
                            // Off-main writing avoids a stalled client blocking the UI.
                            DispatchQueue.global(qos: .utility).async {
                                do { try ControlSocket.send(response, to: peer) }
                                catch let failure as ControlError where failure.code == "MESSAGE_TOO_LARGE" {
                                    try? ControlSocket.send(["apiVersion": ControlWire.apiVersion, "error": failure.object], to: peer)
                                } catch { /* The peer disconnected; accepted jobs stay owned by the app. */ }
                                shutdown(peer, SHUT_WR)
                                completion.signal()
                            }
                        }
                        // Keep descriptor alive until the response finishes. Client reads/writes have deadlines.
                        completion.wait()
                    } catch {
                        let failure = error as? ControlError ?? ControlError("INVALID_REQUEST", error.localizedDescription)
                        try? ControlSocket.send(["apiVersion": ControlWire.apiVersion, "error": failure.object], to: peer)
                    }
                }
            }
        }
    }

    func stop() {
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
            listener = -1
            unlink(ControlSocket.path)
        }
    }

    private func configure(_ fd: Int32) {
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
}
