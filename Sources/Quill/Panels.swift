import AppKit
import SwiftUI

/// A panel that floats over every app without ever activating Quill, so the app you're
/// typing in keeps its focus and caret.
class FloatingPanel: NSPanel {
    private let keyable: Bool

    init(keyable: Bool = false, level: NSWindow.Level = .floating) {
        self.keyable = keyable
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        self.level = level
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a panel that isn't key must react to the first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active  // Quill is never the active app, so force the vibrant look.
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

extension View {
    func panelBackground(radius: CGFloat = 12) -> some View {
        background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

enum Toast {
    private static var panel: FloatingPanel?
    private static var hideWork: DispatchWorkItem?

    /// A short message near `point` (Cocoa coordinates), or near the mouse.
    static func show(_ message: String, near point: CGPoint? = nil) {
        let p = panel ?? FloatingPanel(level: .statusBar)
        panel = p
        p.hasShadow = true
        let view = FirstMouseHostingView(rootView:
            Text(message)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .panelBackground(radius: 9)
                .fixedSize()
        )
        p.contentView = view
        let size = view.fittingSize
        let anchor = point ?? NSEvent.mouseLocation
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height - 18)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        }
        p.setFrame(CGRect(origin: origin, size: size), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
