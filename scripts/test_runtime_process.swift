import Foundation
import Darwin

@main
struct RuntimeProcessRegression {
    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                precondition(written > 0)
                offset += written
            }
        }
    }

    static func main() throws {
        if CommandLine.arguments.count > 1 {
            switch CommandLine.arguments[1] {
            case "large":
                for _ in 0..<128 {
                    writeAll(STDOUT_FILENO, Data(repeating: 65, count: 8192))
                    writeAll(STDERR_FILENO, Data(repeating: 66, count: 8192))
                }
            case "unicode":
                let utf8 = Array("Привет 🌍".utf8)
                for byte in utf8 {
                    writeAll(STDOUT_FILENO, Data([byte]))
                    writeAll(STDERR_FILENO, Data([byte]))
                    usleep(2_000)
                }
                writeAll(STDOUT_FILENO, Data("\r\nlast stdout".utf8))
                writeAll(STDERR_FILENO, Data("\nlast stderr".utf8))
            case "startup-then-silent":
                writeAll(STDOUT_FILENO, Data("started\n".utf8))
                usleep(600_000)
            case "hang":
                signal(SIGTERM, SIG_IGN)
                while true { usleep(100_000) }
            case "normal":
                writeAll(STDOUT_FILENO, Data("out\n".utf8))
                writeAll(STDERR_FILENO, Data("err\n".utf8))
                exit(7)
            default: fatalError("Unknown child mode")
            }
            return
        }
        func process(_ mode: String) -> Process {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [mode]
            return child
        }

        let ordinary = try RuntimeProcessRunner.run(process("normal"))
        precondition(ordinary.exitCode == 7 && ordinary.stdout == "out\n" && ordinary.stderr == "err\n")

        let large = try RuntimeProcessRunner.run(process("large"), idleTimeout: 5)
        precondition(large.exitCode == 0)
        precondition(large.stdout == String(repeating: "A", count: 1_048_576))
        precondition(large.stderr == String(repeating: "B", count: 1_048_576))

        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        let unicode = try RuntimeProcessRunner.run(process("unicode"),
            onStdoutLine: { stdoutLines.append($0) },
            onStderrLine: { stderrLines.append($0) })
        precondition(unicode.stdout == "Привет 🌍\r\nlast stdout")
        precondition(unicode.stderr == "Привет 🌍\nlast stderr")
        precondition(stdoutLines == ["Привет 🌍", "last stdout"])
        precondition(stderrLines == ["Привет 🌍", "last stderr"])

        let timeoutStart = ProcessInfo.processInfo.systemUptime
        let hung = process("hang")
        do {
            _ = try RuntimeProcessRunner.run(hung, idleTimeout: 0.2)
            fatalError("Expected idle timeout")
        } catch DownloadError.processFailed(let message) {
            precondition(message.contains("stopped responding"))
            precondition(!hung.isRunning)
            precondition(ProcessInfo.processInfo.systemUptime - timeoutStart < 6)
        }

        let startupTimeoutStart = ProcessInfo.processInfo.systemUptime
        let startupHung = process("hang")
        do {
            _ = try RuntimeProcessRunner.run(startupHung, startupTimeout: 0.2)
            fatalError("Expected startup timeout")
        } catch DownloadError.processFailed {
            precondition(!startupHung.isRunning)
            precondition(ProcessInfo.processInfo.systemUptime - startupTimeoutStart < 6)
        }
        let silentWork = try RuntimeProcessRunner.run(process("startup-then-silent"), startupTimeout: 0.2)
        precondition(silentWork.exitCode == 0 && silentWork.stdout == "started\n")

        let cancellationStart = ProcessInfo.processInfo.systemUptime
        let cancelled = process("hang")
        do {
            _ = try RuntimeProcessRunner.run(cancelled,
                isCancelled: { ProcessInfo.processInfo.systemUptime - cancellationStart > 0.2 })
            fatalError("Expected cancellation")
        } catch DownloadError.cancelled {
            precondition(!cancelled.isRunning)
            precondition(ProcessInfo.processInfo.systemUptime - cancellationStart < 6)
        }

        let neverStarted = process("normal")
        do {
            _ = try RuntimeProcessRunner.run(neverStarted, isCancelled: { true })
            fatalError("Expected pre-launch cancellation")
        } catch DownloadError.cancelled {
            precondition(!neverStarted.isRunning)
        }

        let descendant = Process()
        descendant.executableURL = URL(fileURLWithPath: "/bin/sh")
        descendant.arguments = ["-c", "sleep 3 & printf parent"]
        let descendantStart = ProcessInfo.processInfo.systemUptime
        let inheritedPipe = try RuntimeProcessRunner.run(descendant, idleTimeout: 1)
        precondition(inheritedPipe.stdout == "parent")
        precondition(ProcessInfo.processInfo.systemUptime - descendantStart < 2)
        let noisyDescendant = Process()
        noisyDescendant.executableURL = URL(fileURLWithPath: "/bin/sh")
        noisyDescendant.arguments = ["-c", "yes descendant & sleep 0.1"]
        let noisyStart = ProcessInfo.processInfo.systemUptime
        let noisyOutput = try RuntimeProcessRunner.run(noisyDescendant, idleTimeout: 1)
        precondition(noisyOutput.stdout.contains("descendant"))
        precondition(ProcessInfo.processInfo.systemUptime - noisyStart < 3)
        // Closing the runner's read pipe makes yes exit through SIGPIPE.
        print("PASS: normal/nonzero exit, dual 1 MiB pipes, split UTF-8, both callbacks/tails, bounded idle/startup timeouts, silent work after startup, cancellation, pre-launch cancellation, inherited silent/noisy descendant pipes")
    }
}
