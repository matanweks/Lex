import AppKit
import SwiftUI

/// Lex's look: the indigo of the app icon, its orange period, and the "L." menu-bar mark.
enum Brand {
    static let indigo = Color(red: 0.36, green: 0.30, blue: 0.92)
    static let deepIndigo = Color(red: 0.17, green: 0.12, blue: 0.56)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)

    static let tagline = "Fix, refine, translate, read aloud and dictate, in every app."
    static let repo = URL(string: "https://github.com/matanweks/Lex")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The app icon's "L." drawn as a menu-bar template image, so macOS colours it like every
    /// other icon there. Dimmed when Lex is paused.
    static func menuBarMark(dimmed: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let ink = NSColor.black.withAlphaComponent(dimmed ? 0.4 : 1).cgColor
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(2.6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: 4.5, y: 14.6))
            ctx.addLine(to: CGPoint(x: 4.5, y: 3.6))
            ctx.addLine(to: CGPoint(x: 10.2, y: 3.6))
            ctx.strokePath()
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: 12.2, y: 1.7, width: 3.8, height: 3.8))
            return true
        }
        image.isTemplate = true
        return image
    }
}
