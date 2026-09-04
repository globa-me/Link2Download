import SwiftUI
import AppKit

enum Theme {
    static let accent = Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.66, blue: 0.95, alpha: 1.0))
    static let accentStrong = Color(nsColor: NSColor(calibratedRed: 0.05, green: 0.50, blue: 0.86, alpha: 1.0))
    static let panel = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        }
        return NSColor.windowBackgroundColor
    })

    static let rowBackground = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 0.96)
        }
        return NSColor.controlBackgroundColor.withAlphaComponent(0.96)
    })

    static let secondaryText = Color(nsColor: .secondaryLabelColor)
}
