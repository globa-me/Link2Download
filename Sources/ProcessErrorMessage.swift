import Foundation

enum ProcessErrorMessage {
    static func clean(stderr: String, stdout: String) -> String {
        func lines(_ output: String) -> [String] {
            // yt-dlp can print "ERROR: \r[download] Got error: ...". A carriage
            // return overwrites console progress, but is not an error boundary.
            output.replacingOccurrences(of: "\r", with: "")
                .split(separator: "\n")
                .map { sanitize(String($0)) }
                .filter { !$0.isEmpty && !isInternalProtocolLine($0) }
        }

        let stderrLines = lines(stderr)
        let stdoutLines = lines(stdout)
        let errorLines = (stderrLines + stdoutLines).compactMap { line -> String? in
            guard let range = line.range(of: "ERROR:") else { return nil }
            let message = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return message == "ERROR:" ? nil : message
        }
        if !errorLines.isEmpty { return errorLines.joined(separator: "\n") }

        let fallback = (stderrLines.isEmpty ? stdoutLines : stderrLines)
            .filter { $0 != "ERROR:" }
        return fallback.isEmpty ? "yt-dlp failed" : fallback.joined(separator: "\n")
    }

    private static func isInternalProtocolLine(_ line: String) -> Bool {
        line.hasPrefix("__L2D_") ||
            line.contains("__L2D_META__:") ||
            line.contains("__L2D_ITEM__:") ||
            line.contains("__L2D_PROGRESS__:") ||
            line.contains("__L2D_FILE__:") ||
            line.contains("__L2D_STATUS_")
    }

    private static func sanitize(_ raw: String) -> String {
        let escape = "\u{001B}"
        let ansiPattern = "\(escape)\\[[0-9;?]*[ -/]*[@-~]"
        return raw.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
