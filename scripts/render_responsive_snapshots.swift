import AppKit
import SwiftUI

@main
@MainActor
struct ResponsiveSnapshotRenderer {
    private struct Scenario {
        let name: String
        let size: NSSize
        let smartMode: Bool
    }

    static func main() throws {
        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/link2download-responsive-snapshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let scenarios = [
            Scenario(name: "narrow-smart", size: NSSize(width: 640, height: 700), smartMode: true),
            Scenario(name: "narrow-manual", size: NSSize(width: 640, height: 700), smartMode: false),
            Scenario(name: "compact-smart", size: NSSize(width: 900, height: 760), smartMode: true),
            Scenario(name: "compact-manual", size: NSSize(width: 900, height: 760), smartMode: false),
            Scenario(name: "regular-smart", size: NSSize(width: 1320, height: 820), smartMode: true),
            Scenario(name: "regular-manual", size: NSSize(width: 1320, height: 820), smartMode: false)
        ]

        let suiteName = "Link2Download.snapshots.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        var preferences = DownloadPreferences.default()
        preferences.saveDirectory = historyDirectory.appendingPathComponent("downloads").path
        defaults.set(try JSONEncoder().encode(preferences), forKey: "link2download.preferences")
        let settings = SettingsStore(defaults: defaults)
        let manager = DownloadManager(settings: settings, historyDirectory: historyDirectory)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate(ignoringOtherApps: true)

        for scenario in scenarios {
            settings.smartModeEnabled = scenario.smartMode
            let destination = outputDirectory.appendingPathComponent("\(scenario.name).png")
            try render(
                MainView(settings: settings, manager: manager),
                size: scenario.size,
                destination: destination
            )
            print(destination.path)
        }

        // Exercise the longer localized cancellation action with a real source
        // path, so both source actions and the transcode cancellation are shown.
        settings.language = .russian
        settings.smartModeEnabled = true
        let source = historyDirectory.appendingPathComponent("source.mp4")
        try Data("snapshot fixture".utf8).write(to: source)
        var record = DownloadRecord(sourceURL: "https://example.org/video", serviceName: "YouTube",
            title: "Аппаратное перекодирование", durationSeconds: 363, status: .downloading,
            progress: 0.6, downloadProgress: 1, processingProgress: 0.2,
            statusMessage: settings.t("progress.appleHWTranscode"), kind: .video,
            qualityLabel: "1920×1080", outputFormat: "MP4", filePath: source.path,
            processingStage: .hardwareTranscode, operationType: .download, transcodeSourcePath: source.path)
        manager.records = [record]
        for width in [CGFloat(640), CGFloat(1320)] {
            let destination = outputDirectory.appendingPathComponent("transcode-active-\(Int(width)).png")
            try render(MainView(settings: settings, manager: manager),
                size: NSSize(width: width, height: 700), destination: destination)
            print(destination.path)
        }
        record.status = .cancelled
        record.processingStage = nil
        record.processingProgress = nil
        manager.records = [record]
        let destination = outputDirectory.appendingPathComponent("transcode-cancelled.png")
        try render(MainView(settings: settings, manager: manager),
            size: NSSize(width: 900, height: 700), destination: destination)
        print(destination.path)
    }

    private static func render<Content: View>(
        _ content: Content,
        size: NSSize,
        destination: URL
    ) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.couldNotCreateBitmap
        }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncodePNG
        }
        try pngData.write(to: destination, options: .atomic)
        window.orderOut(nil)
    }

    private enum SnapshotError: Error {
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }
}
