import AppKit
import LexCore
import SwiftUI

/// Draws the underlines. Lives in a click-through panel sized to the issues it shows.
final class UnderlineView: NSView {
    struct Item {
        let issue: Issue
        let rects: [CGRect]  // view coordinates
    }

    var items: [Item] = [] { didSet { needsDisplay = true } }
    var hoveredID: String? { didSet { if hoveredID != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        for item in items {
            let color = Self.color(for: item.issue)
            for r in item.rects {
                if item.issue.id == hoveredID {
                    color.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: 0), xRadius: 3, yRadius: 3).fill()
                }
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY - 1, width: max(r.width, 4), height: 2), xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    static func color(for issue: Issue) -> NSColor {
        issue.kind.isCorrectness
            ? NSColor(srgbRed: 0.91, green: 0.27, blue: 0.30, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.47, blue: 0.96, alpha: 1)
    }
}

final class BadgeModel: ObservableObject {
    @Published var count = 0
    @Published var checking = false
    @Published var aiOn = true
}

struct BadgeView: View {
    @ObservedObject var model: BadgeModel
    let onClick: () -> Void
    @State private var spin = false

    var body: some View {
        Button(action: onClick) {
            ZStack {
                Circle().fill(fill)
                if model.count > 0 {
                    Text("\(min(model.count, 99))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                }
                if model.checking {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .padding(1.5)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                        }
                        .onDisappear { spin = false }
                }
            }
            .frame(width: 18, height: 18)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .help("Lex: refine this whole field")
    }

    private var fill: Color {
        if model.count > 0 { return Color(nsColor: NSColor(srgbRed: 0.91, green: 0.27, blue: 0.30, alpha: 1)) }
        return model.aiOn ? Color(red: 0.16, green: 0.62, blue: 0.40) : Color.gray
    }
}

struct SuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(red: 0.16, green: 0.62, blue: 0.40).opacity(configuration.isPressed ? 0.32 : 0.17)))
            .foregroundStyle(Color(red: 0.08, green: 0.48, blue: 0.29))
            .contentShape(Rectangle())
    }
}

struct SuggestionCardView: View {
    let issue: Issue
    let apply: (String) -> Void
    let ignore: () -> Void
    let learn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: UnderlineView.color(for: issue))).frame(width: 7, height: 7)
                Text(issue.kind.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            let long = issue.original.count + (issue.replacements.first?.count ?? 0) > 34
            if long {
                VStack(alignment: .leading, spacing: 6) {
                    original
                    replacements
                }
            } else {
                HStack(spacing: 6) {
                    original
                    if !issue.replacements.isEmpty {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    replacements
                }
            }
            if !issue.message.isEmpty {
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button("Ignore", action: ignore)
                if issue.kind == .spelling {
                    Button("Add to dictionary", action: learn)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .panelBackground(radius: 10)
    }

    private var original: some View {
        Text(issue.original)
            .strikethrough(true, color: .red.opacity(0.6))
            .foregroundStyle(.secondary)
            .lineLimit(3)
    }

    @ViewBuilder private var replacements: some View {
        if issue.replacements.isEmpty {
            Text("No suggestion").font(.callout).foregroundStyle(.tertiary)
        } else {
            ForEach(issue.replacements, id: \.self) { r in
                Button { apply(r) } label: {
                    Text(r.isEmpty ? "Remove" : r).fontWeight(.semibold).lineLimit(3).multilineTextAlignment(.leading)
                }
                .buttonStyle(SuggestionButtonStyle())
            }
        }
    }
}

/// Underlines, the badge and the hover card for the focused field.
final class OverlayController {
    var onApply: ((Issue, String) -> Void)?
    var onIgnore: ((Issue) -> Void)?
    var onLearn: ((Issue) -> Void)?
    var onBadgeClick: (() -> Void)?

    private let underlineWindow = FloatingPanel(level: .floating)
    private let underlineView = UnderlineView()
    private let badgePanel = FloatingPanel(level: .floating)
    private let badgeModel = BadgeModel()
    private let cardPanel = FloatingPanel(level: .popUpMenu)
    private var cardIssueID: String?
    private var items: [(issue: Issue, rects: [CGRect])] = []  // Cocoa screen coordinates
    private var hoverWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var fieldFrame: CGRect?  // Cocoa coordinates
    private var cardShownAt = Date.distantPast

    init() {
        underlineWindow.ignoresMouseEvents = true
        underlineWindow.hasShadow = false
        underlineWindow.contentView = underlineView
        badgePanel.hasShadow = false
        badgePanel.contentView = FirstMouseHostingView(rootView: BadgeView(model: badgeModel) { [weak self] in self?.onBadgeClick?() })
        cardPanel.acceptsMouseMovedEvents = true
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in self?.mouseMoved(); return e }) {
            monitors.append(m)
        }
        // A click anywhere else (clicks on the card itself are local events) dismisses the card.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.hideCard() }) {
            monitors.append(m)
        }
    }

    func show(issues: [Issue], rects: [String: [CGRect]], field: FieldSnapshot, badge: (count: Int, checking: Bool, aiOn: Bool), showBadge: Bool) {
        items = issues.compactMap { issue in rects[issue.id].map { (issue, $0.map(ScreenGeometry.toCocoa)) } }
        fieldFrame = ScreenGeometry.toCocoa(field.visible.isEmpty ? field.frame : field.visible)
        if items.isEmpty {
            underlineWindow.orderOut(nil)
            underlineView.items = []
        } else {
            let bounds = items.flatMap(\.rects).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
            underlineWindow.setFrame(bounds, display: false)
            underlineView.frame = CGRect(origin: .zero, size: bounds.size)
            underlineView.items = items.map { item in
                UnderlineView.Item(issue: item.issue, rects: item.rects.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) })
            }
            underlineWindow.orderFrontRegardless()
        }
        if let id = cardIssueID, !items.contains(where: { $0.issue.id == id }) { hideCard() }
        updateBadge(badge, field: field, visible: showBadge)
    }

    func updateBadge(_ badge: (count: Int, checking: Bool, aiOn: Bool), field: FieldSnapshot?, visible: Bool) {
        guard visible, let field else { badgePanel.orderOut(nil); return }
        let f = ScreenGeometry.toCocoa(field.visible.isEmpty ? field.frame : field.visible)
        guard f.width > 60, f.height > 14 else { badgePanel.orderOut(nil); return }
        if badgeModel.count != badge.count { badgeModel.count = badge.count }
        if badgeModel.checking != badge.checking { badgeModel.checking = badge.checking }
        if badgeModel.aiOn != badge.aiOn { badgeModel.aiOn = badge.aiOn }
        let size = CGSize(width: 20, height: 20)
        // Big editors: inside the bottom-right corner. Composers and single lines: just outside it.
        var origin = f.height > 140 ? CGPoint(x: f.maxX - size.width - 8, y: f.minY + 8) : CGPoint(x: f.maxX + 4, y: f.minY + 1)
        if let screen = ScreenGeometry.screen(containing: f)?.frame, origin.x + size.width > screen.maxX {
            origin.x = f.maxX - size.width - 4
        }
        let frame = CGRect(origin: origin, size: size)
        if badgePanel.frame != frame { badgePanel.setFrame(frame, display: true) }
        if !badgePanel.isVisible { badgePanel.orderFrontRegardless() }
    }

    func clear() {
        items = []
        underlineView.items = []
        underlineWindow.orderOut(nil)
        badgePanel.orderOut(nil)
        hideCard()
    }

    func hideCard() {
        hoverWork?.cancel()
        hideWork?.cancel()
        hideWork = nil
        cardIssueID = nil
        underlineView.hoveredID = nil
        cardPanel.orderOut(nil)
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if cardPanel.isVisible, cardPanel.frame.insetBy(dx: -6, dy: -6).contains(p) {
            hideWork?.cancel(); hideWork = nil
            return
        }
        let hit = items.first { $0.rects.contains { $0.insetBy(dx: -1, dy: -3).contains(p) } }
        underlineView.hoveredID = hit?.issue.id ?? (cardPanel.isVisible ? cardIssueID : nil)
        if let hit {
            hideWork?.cancel(); hideWork = nil
            if cardPanel.isVisible, hit.issue.id == cardIssueID { return }
            hoverWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.showCard(for: hit.issue.id) }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        } else {
            hoverWork?.cancel()
            guard cardPanel.isVisible, hideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.hideCard() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func showCard(for id: String) {
        guard let item = items.first(where: { $0.issue.id == id }), let anchor = item.rects.first else { return }
        let issue = item.issue
        cardIssueID = id
        underlineView.hoveredID = id
        let view = FirstMouseHostingView(rootView: SuggestionCardView(
            issue: issue,
            apply: { [weak self] r in
                // A click that lands as the card appears was meant for the text underneath.
                guard let self, Date().timeIntervalSince(self.cardShownAt) > 0.35 else { return }
                self.hideCard()
                self.onApply?(issue, r)
            },
            ignore: { [weak self] in self?.hideCard(); self?.onIgnore?(issue) },
            learn: { [weak self] in self?.hideCard(); self?.onLearn?(issue) }
        ))
        cardPanel.contentView = view
        let size = view.fittingSize
        let screen = ScreenGeometry.screen(containing: anchor)?.visibleFrame ?? .infinite
        var origin: CGPoint
        if let field = fieldFrame, field.height <= 160 {
            // Message boxes and inputs: open outside the field so the card never sits on top of
            // text you might click into. Above the field, or below it when there's no room.
            origin = CGPoint(x: anchor.minX - 10, y: field.maxY + 6)
            if origin.y + size.height > screen.maxY - 4 { origin.y = field.minY - 6 - size.height }
        } else {
            origin = CGPoint(x: anchor.minX - 10, y: anchor.minY - 6 - size.height)
            if origin.y < screen.minY + 4 { origin.y = anchor.maxY + 6 }
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        cardPanel.setFrame(CGRect(origin: origin, size: size), display: true)
        cardPanel.orderFrontRegardless()
        cardShownAt = Date()
    }
}
