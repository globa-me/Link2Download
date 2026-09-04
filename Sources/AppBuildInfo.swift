import Foundation

enum AppBuildInfo {
    static var version: String {
        bundleValue(for: "CFBundleShortVersionString") ?? "1.4.1"
    }

    static var build: String? {
        let raw = bundleValue(for: "CFBundleVersion")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static var displayVersion: String {
        guard let build else {
            return version
        }
        return "\(version) (\(build))"
    }

    private static func bundleValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
