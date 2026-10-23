import Foundation

enum DiagnosticRedactor {
    /// Applied to new logs and to legacy log/report output before handing it to agents.
    static func redact(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"']+"#, options: [.caseInsensitive]) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            let base = raw.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? "[URL]"
            var components = URLComponents(string: base)
            components?.user = nil
            components?.password = nil
            result.replaceSubrange(range, with: components?.string ?? "[URL]")
        }
        return result
    }
}
