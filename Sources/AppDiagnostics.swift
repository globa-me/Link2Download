import Foundation

final class AppDiagnostics: @unchecked Sendable {
    static let shared = AppDiagnostics()

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    let logsDirectoryURL: URL
    let logFileURL: URL

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "Link2Download.AppDiagnostics", qos: .utility)
    private let formatter: ISO8601DateFormatter
    private let maxLogBytes = 2_000_000
    private let retainedLogBytes = 1_200_000

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let appSupport = support.appendingPathComponent("Link2Download", isDirectory: true)
        let logsDir = appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        self.logsDirectoryURL = logsDir
        self.logFileURL = logsDir.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = iso

        log(
            .info,
            "Diagnostics started; app_arch=\(Self.runtimeArchitecture) os=\(ProcessInfo.processInfo.operatingSystemVersionString) version=\(AppBuildInfo.displayVersion) bundle=\(Bundle.main.bundleURL.path)"
        )
    }

    func log(_ level: Level, _ message: String) {
        let normalized = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " | ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(normalized)\n"
        queue.async { [weak self] in
            self?.append(line)
        }
    }

    func readTail(maxBytes: Int = 160_000) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: logFileURL), !data.isEmpty else {
                return ""
            }
            if data.count <= maxBytes {
                return String(data: data, encoding: .utf8) ?? ""
            }
            let start = data.count - max(1, maxBytes)
            let tail = data.subdata(in: start..<data.count)
            return String(data: tail, encoding: .utf8) ?? ""
        }
    }

    private func append(_ line: String) {
        guard let encoded = line.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
        } catch {
            return
        }

        truncateIfNeeded()
    }

    private func truncateIfNeeded() {
        guard let attrs = try? fileManager.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxLogBytes else {
            return
        }
        guard let data = try? Data(contentsOf: logFileURL),
              !data.isEmpty else {
            return
        }

        let start = max(0, data.count - retainedLogBytes)
        let tail = data.subdata(in: start..<data.count)
        try? tail.write(to: logFileURL, options: .atomic)
    }

    static var runtimeArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}
