import Foundation
import Darwin

/// Drains both pipes on one thread. Never waits for process exit with a full pipe,
/// and never leaves a FileHandle callback racing with final output collection.
enum RuntimeProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func run(
        _ process: Process,
        idleTimeout: TimeInterval? = nil,
        startupTimeout: TimeInterval? = nil,
        isCancelled: () -> Bool = { false },
        onStdoutLine: ((String) -> Void)? = nil,
        onStderrLine: ((String) -> Void)? = nil
    ) throws -> Result {
        let pipes = [Pipe(), Pipe()]
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]
        process.standardInput = FileHandle.nullDevice
        var output = [Data(), Data()]
        var pending = [Data(), Data()]
        var descriptors = pipes.map {
            pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        }
        defer {
            for pipe in pipes {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        if isCancelled() { throw DownloadError.cancelled }
        try process.run()
        var lastActivity = ProcessInfo.processInfo.systemUptime
        var stopTime: TimeInterval?
        var cancelled = false
        var timedOut = false
        var timeoutDuration: TimeInterval?
        var receivedOutput = false
        var sentKill = false
        var observedExitTime: TimeInterval?
        var buffer = [UInt8](repeating: 0, count: 65_536)

        func emit(_ index: Int, _ bytes: Data) {
            let line = String(decoding: bytes, as: UTF8.self)
            if !line.isEmpty {
                (index == 0 ? onStdoutLine : onStderrLine)?(line)
            }
        }

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if stopTime == nil, process.isRunning {
                cancelled = isCancelled()
                if let idleTimeout, now - lastActivity >= idleTimeout {
                    timeoutDuration = idleTimeout
                } else if !receivedOutput, let startupTimeout, now - lastActivity >= startupTimeout {
                    timeoutDuration = startupTimeout
                }
                timedOut = timeoutDuration != nil
                if cancelled || timedOut {
                    stopTime = now
                    process.terminate()
                }
            }
            if let stopTime, now - stopTime >= 3, process.isRunning, !sentKill {
                kill(process.processIdentifier, SIGKILL)
                sentKill = true
            }

            let running = process.isRunning
            if !running {
                if observedExitTime == nil { observedExitTime = now }
                // A continuously writing descendant must not keep this call alive
                // after the process we launched has exited. Parent pipe buffers are
                // small and are drained immediately; allow up to one second for tails.
                if let observedExitTime, now - observedExitTime >= 1 { break }
            }
            let ready = poll(&descriptors, nfds_t(descriptors.count), running ? 100 : 0)
            if ready < 0, errno != EINTR {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw DownloadError.processFailed("Cannot read runtime process output (errno \(errno)).")
            }
            var readBytes = false
            for index in descriptors.indices where descriptors[index].fd >= 0 {
                let events = descriptors[index].revents
                guard events & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }
                let count = read(descriptors[index].fd, &buffer, buffer.count)
                if count > 0 {
                    readBytes = true
                    receivedOutput = true
                    lastActivity = ProcessInfo.processInfo.systemUptime
                    let bytes = Data(buffer.prefix(count))
                    output[index].append(bytes)
                    pending[index].append(bytes)
                    // Decode complete lines, not arbitrary read chunks (UTF-8 may split).
                    while let boundary = pending[index].firstIndex(where: { $0 == 10 || $0 == 13 }) {
                        emit(index, Data(pending[index][..<boundary]))
                        pending[index].removeSubrange(...boundary)
                    }
                } else if count == 0 || (count < 0 && errno != EINTR) {
                    descriptors[index].fd = -1
                }
            }
            // A descendant can inherit a pipe. Drain available bytes after exit,
            // but do not block forever waiting for that descendant to close it.
            if !running && !readBytes { break }
        }
        process.waitUntilExit()
        for index in pending.indices { emit(index, pending[index]) }
        if cancelled || isCancelled() { throw DownloadError.cancelled }
        if timedOut {
            throw DownloadError.processFailed(
                "\(process.executableURL?.lastPathComponent ?? "Runtime") stopped responding for \(Int(timeoutDuration ?? 0)) seconds. Please retry."
            )
        }
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: output[0], as: UTF8.self),
            stderr: String(decoding: output[1], as: UTF8.self)
        )
    }
}
