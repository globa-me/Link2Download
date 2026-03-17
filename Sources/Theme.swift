import SwiftUI
import AppKit

enum Theme {
    static let accent = Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.66, blue: 0.95, alpha: 1.0))
    static let accentStrong = Color(nsColor: NSColor(calibratedRed: 0.05, green: 0.50, blue: 0.86, alpha: 1.0))
    static let panel = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.18, alpha: 1.0)
        }
        return NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 1.0)
    })

    static let rowBackground = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.23, alpha: 0.92)
        }
        return NSColor.white.withAlphaComponent(0.90)
    })

    static let secondaryText = Color(nsColor: .secondaryLabelColor)
}
