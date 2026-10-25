import Foundation
import Darwin

@main
struct TranscodeCancellationRegression {
    static let sourceData = Data("original video".utf8)

    static func main() throws {
        // The test executable also acts as deterministic ffprobe/ffmpeg fixtures.
        // No network, browser, GPU or installed app state is used.
        if CommandLine.arguments.contains("-show_entries") {
            try probeFixture()
            return
        }
        if CommandLine.arguments.contains("-progress") {
            try conversionFixture()
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Link2Download-transcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let tools = YTDLPService.RuntimeTools(ytdlp: executable, ffmpeg: executable,
            ffprobe: executable, ffmpegDir: directory)
        var preferences = DownloadPreferences.default()
        preferences.saveDirectory = directory.path

        for mode in ["before-start", "probe", "between-processes", "active", "before-commit", "output-probe"] {
            let folder = directory.appendingPathComponent(mode, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("\(mode).mp4")
            try sourceData.write(to: source)
            let service = YTDLPService()
            let taskID = UUID()
            if mode == "before-start" { service.cancel(taskID: taskID) }
            let monitor = DispatchGroup()
            if mode == "probe" || mode == "output-probe" {
                monitor.enter()
                DispatchQueue.global().async {
                    defer { monitor.leave() }
                    let marker = folder.appendingPathComponent("probe-started")
                    let deadline = Date().addingTimeInterval(10)
                    while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { usleep(10_000) }
                    precondition(FileManager.default.fileExists(atPath: marker.path), "Probe did not start")
                    service.cancel(taskID: taskID)
                }
            }
            var hardwareStage = false
            var softwareStage = false
            let started = Date()
            do {
                _ = try service.transcodeVideo(sourcePath: source.path, preferences: preferences,
                    tools: tools, taskID: taskID, replaceOriginal: true,
                    onProgress: { progress, message, _ in
                        if message == "__L2D_STATUS_APPLE_HW_TRANSCODE__" {
                            hardwareStage = true
                            if mode == "between-processes" { service.cancel(taskID: taskID) }
                        }
                        if message == "__L2D_STATUS_APPLE_SW_TRANSCODE__" { softwareStage = true }
                        if mode == "active", hardwareStage, let progress, progress > 0.01 {
                            service.cancel(taskID: taskID)
                        }
                        if mode == "before-commit", progress == 1 { service.cancel(taskID: taskID) }
                    })
                fatalError("Expected cancellation: \(mode)")
            } catch DownloadError.cancelled {}
            precondition(monitor.wait(timeout: .now() + 1) == .success)
            precondition(Date().timeIntervalSince(started) < 8, "Cancellation was not bounded: \(mode)")
            let retainedSource = try Data(contentsOf: source)
            precondition(retainedSource == sourceData, "Source changed: \(mode)")
            let remaining = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            precondition(!remaining.contains { $0.pathExtension == "mov" }, "MOV was retained: \(mode)")
            precondition(!softwareStage, "Cancellation must not start software fallback")
            if let pidText = try? String(contentsOf: folder.appendingPathComponent("conversion-pid")),
               let pid = Int32(pidText) {
                precondition(kill(pid, 0) == -1 && errno == ESRCH, "Conversion child still running")
            }
            // A caught optional probe must not consume cancellation. Only worker
            // exit can reset it, after which the same history row can be retried.
            do {
                try service.checkCancellation(taskID: taskID)
                fatalError("Cancellation was consumed: \(mode)")
            } catch DownloadError.cancelled {}
            service.finishTask(taskID: taskID)
            try service.checkCancellation(taskID: taskID)
            let retrySource = folder.appendingPathComponent("retry.mp4")
            try sourceData.write(to: retrySource)
            let retried = try service.transcodeVideo(sourcePath: retrySource.path, preferences: preferences,
                tools: tools, taskID: taskID, replaceOriginal: false, onProgress: { _, _, _ in })
            precondition(FileManager.default.fileExists(atPath: retried.outputPath))
            let retainedRetrySource = try Data(contentsOf: retrySource)
            precondition(retainedRetrySource == sourceData)
            service.finishTask(taskID: taskID)
            print("PASS: \(mode) cancellation, source/temp/process safety, retry")
        }
    }

    static func probeFixture() throws {
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args.last!)
        if source.lastPathComponent == "probe.mp4" || source.lastPathComponent.hasPrefix(".output-probe.") {
            try Data().write(to: source.deletingLastPathComponent().appendingPathComponent("probe-started"))
            while true { usleep(100_000) }
        }
        let entries = args[args.firstIndex(of: "-show_entries")! + 1]
        switch entries {
        case "format=duration": print("10")
        case "stream=codec_name": print(args.contains("v:0") ? "vp9" : "aac")
        case "stream=width,height": print("1920x1080")
        default: print("2000000")
        }
    }

    static func conversionFixture() throws {
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args[args.firstIndex(of: "-i")! + 1])
        let output = URL(fileURLWithPath: args.last!)
        try Data("converted video".utf8).write(to: output)
        try Data("\(getpid())".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("conversion-pid"))
        if source.lastPathComponent == "active.mp4" {
            // Model an encoder that ignores SIGTERM: the runner must escalate.
            signal(SIGTERM, SIG_IGN)
            FileHandle.standardOutput.write(Data("out_time_us=2000000\n".utf8))
            while true { usleep(100_000) }
        }
        print("progress=end")
    }
}
