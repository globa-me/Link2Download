import Foundation

enum AppFormatters {
    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let compactNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    static func durationString(from seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    static func sizeString(from bytes: Int64?) -> String {
        guard let bytes else { return "--" }
        return byteFormatter.string(fromByteCount: bytes)
    }

    static func speedString(from bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "--" }
        let megabitsPerSecond = (bytesPerSecond * 8.0) / 1_000_000.0
        if megabitsPerSecond >= 1.0 {
            let value = compactNumberFormatter.string(from: NSNumber(value: megabitsPerSecond)) ?? "\(megabitsPerSecond)"
            return "\(value) Mbps"
        }
        let kilobitsPerSecond = (bytesPerSecond * 8.0) / 1_000.0
        let value = compactNumberFormatter.string(from: NSNumber(value: kilobitsPerSecond)) ?? "\(kilobitsPerSecond)"
        return "\(value) Kbps"
    }

    static func remainingTimeString(from seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "--:--" }
        return durationString(from: ceil(seconds))
    }

    static func relativeDateString(from date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func dateTimeString(from date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }
}
