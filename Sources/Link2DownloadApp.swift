import SwiftUI
import AppKit

/// AppKit owns window creation so automation can start the same app without a window on macOS 12.
@main
enum Link2DownloadApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = Link2DownloadApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class Link2DownloadApplicationDelegate: NSObject, NSApplicationDelegate {
    private var lease: ControlLease?
    private var server: ControlServer?
    private var controller: AutomationController?
    private var settings: SettingsStore?
    private var manager: DownloadManager?
    private var window: NSWindow?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // Acquire ownership before loading history: a duplicate process must not change the owner's jobs.
            lease = try ControlLease()
            let testHome = ProcessInfo.processInfo.environment["LINK2DOWNLOAD_TEST_HOME"]
            let defaults = testHome.flatMap { UserDefaults(suiteName: "com.gzakharov.link2download.test.\(URL(fileURLWithPath: $0).lastPathComponent)") } ?? .standard
            let settings = SettingsStore(defaults: defaults)
            if let testHome { settings.saveDirectory = testHome + "/downloads" }
            let manager = DownloadManager(settings: settings, historyDirectory: testHome.map { URL(fileURLWithPath: $0) })
            let controller = AutomationController(settings: settings, manager: manager)
            controller.presentUI = { [weak self] action in self?.present(action) }
            controller.quit = { [weak self] in
                // AppKit's terminateLater enters a nested run loop. Starting it
                // inside a main-dispatch callback prevents queued MainActor work
                // from draining. A run-loop selector keeps shutdown reentrant.
                self?.perform(#selector(Link2DownloadApplicationDelegate.requestControlQuit), with: nil, afterDelay: 0, inModes: [.common])
            }
            self.settings = settings
            self.manager = manager
            self.controller = controller
            let server = ControlServer { [controller] method, params in try controller.handle(method, params) }
            try server.start()
            self.server = server
            installMenu()
            if CommandLine.arguments.contains("--background-control") {
                NSApp.setActivationPolicy(.accessory)
            } else { showWindow() }
        } catch {
            if let failure = error as? ControlError, failure.code == "APP_ALREADY_RUNNING" {
                if !CommandLine.arguments.contains("--background-control") {
                    DispatchQueue.global().async {
                        _ = try? ControlClient(autoLaunch: false).call(method: "ui.show")
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                    return
                }
            } else {
                FileHandle.standardError.write(Data("Link2Download startup failed: \(error.localizedDescription)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    private func showWindow() {
        guard let settings, let manager else { return }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Link2Download"
            window.minSize = NSSize(width: 620, height: 520)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(settings: settings, manager: manager))
            window.setFrameAutosaveName("Link2Download.MainWindow")
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(_ action: String) {
        if action == "hide" { NSApp.hide(nil); return }
        showWindow()
        if action == "settings" || action == "about" {
            // Allow a newly created hosting view to install its notification subscription.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .link2DownloadControlUI, object: nil, userInfo: ["panel": action])
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else { return .terminateNow }
        if terminating { return .terminateLater }
        terminating = true
        controller?.beginShutdown()
        AppDiagnostics.shared.log(.info, "Application shutdown requested")
        for record in manager.records where record.status == .queued || record.status == .downloading {
            manager.cancel(recordID: record.id)
        }
        if manager.activeDownloadID == nil && manager.activeTranscodeID == nil {
            do { try manager.flushHistory() }
            catch { AppDiagnostics.shared.log(.error, "History flush at shutdown failed: \(error.localizedDescription)") }
            server?.stop()
            return .terminateNow
        }
        Task { @MainActor in
            while manager.activeDownloadID != nil || manager.activeTranscodeID != nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            do { try manager.flushHistory() }
            catch { AppDiagnostics.shared.log(.error, "History flush at shutdown failed: \(error.localizedDescription)") }
            server?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installMenu() {
        let menu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "About Link2Download", action: #selector(showAbout), keyEquivalent: "")
        applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide Link2Download", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: "Quit Link2Download", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenuItem.submenu = applicationMenu
        menu.addItem(applicationMenuItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func showSettings() { present("settings") }
    @objc private func showAbout() { present("about") }
    @objc private func requestControlQuit() { NSApp.terminate(nil) }
}

extension Notification.Name {
    static let link2DownloadControlUI = Notification.Name("Link2Download.Control.UI")
}
