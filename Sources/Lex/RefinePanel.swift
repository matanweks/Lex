import AppKit
import Combine
import LexCore
import SwiftUI

final class RefineModel: ObservableObject {
    @Published var scope: RefineScope = .sentence
    @Published var original = ""
    /// Each finished refinement; the last one is what Enter will write back.
    @Published var versions: [String] = []
    @Published var streamingText: String?
    @Published var running: RefineAction?
    @Published var error: String?
    @Published var instruction = ""
    @Published var firstTokenMs: Int?
    @Published var totalMs: Int?
    @Published var showDiff = true
    @Published var acceptWhenDone = false
    @Published var lastRunUnchanged = false
    @Published var modelLabel = ""

    var latest: String { versions.last ?? original }
    var isStreaming: Bool { streamingText != nil }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

struct RefineView: View {
    @ObservedObject var model: RefineModel
    let onAction: (RefineAction) -> Void
    let onScope: (RefineScope) -> Void
    let onAccept: () -> Void
    let onInstruction: () -> Void
    @FocusState private var instructionFocused: Bool

    private let green = Color(red: 0.16, green: 0.62, blue: 0.40)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            result
            FlowLayout(spacing: 6) {
                ForEach(Array(RefineAction.all.enumerated()), id: \.element.id) { index, action in
                    chip(action, shortcut: index + 1)
                }
            }
            instructionField
            footer
        }
        .padding(14)
        .frame(width: 540)
        .panelBackground(radius: 14)
        .onAppear { DispatchQueue.main.async { instructionFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").foregroundStyle(green)
            Text("Refine").font(.headline)
            Picker("", selection: Binding(get: { model.scope }, set: { onScope($0) })) {
                ForEach(RefineScope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .help("Tab switches scope")
            Spacer()
            if model.isStreaming {
                ProgressView().controlSize(.small)
            }
            if let ms = model.firstTokenMs {
                Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .help("Time to first word")
            }
        }
    }

    @ViewBuilder private var result: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                Text(displayText)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.lastRunUnchanged, !model.isStreaming {
                    Label("Already reads well, nothing to change.", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(green)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var displayText: AttributedString {
        if let streaming = model.streamingText {
            var s = AttributedString(streaming.isEmpty ? " " : streaming)
            s.swiftUI.foregroundColor = .primary
            var cursor = AttributedString(" ▍")
            cursor.swiftUI.foregroundColor = green
            return s + cursor
        }
        if model.showDiff, !model.versions.isEmpty { return Self.diff(model.original, model.latest, green: green) }
        return AttributedString(model.latest)
    }

    static func diff(_ a: String, _ b: String, green: Color) -> AttributedString {
        var out = AttributedString()
        for chunk in WordDiff.diff(a, b) {
            switch chunk {
            case .same(let s):
                out += AttributedString(s)
            case .change(let removed, let added):
                if !removed.trimmingCharacters(in: .whitespaces).isEmpty {
                    var r = AttributedString(removed)
                    r.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .red.opacity(0.7))
                    r.swiftUI.foregroundColor = .secondary
                    out += r
                }
                if !added.isEmpty {
                    var ad = AttributedString(added)
                    ad.swiftUI.backgroundColor = green.opacity(0.2)
                    out += ad
                }
            }
        }
        return out
    }

    private func chip(_ action: RefineAction, shortcut: Int) -> some View {
        let active = model.running?.id == action.id
        return Button { onAction(action) } label: {
            HStack(spacing: 4) {
                Text(action.label)
                Text("⌘\(shortcut)").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(active ? green.opacity(0.22) : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(active ? green.opacity(0.6) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var instructionField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(.tertiary)
            TextField("Or say how to change it, e.g. “less salesy” or “add a thank-you”", text: $model.instruction)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($instructionFocused)
            if !model.instruction.isEmpty {
                Text("↵ Apply").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("⌘C", "Copy")
            if !model.versions.isEmpty { hint("⌘Z", "Undo") }
            hint("⌘D", model.showDiff ? "Hide changes" : "Show changes")
            hint("esc", "Close")
            Spacer()
            Text(model.modelLabel).font(.caption).foregroundStyle(.tertiary)
            Button(action: onAccept) {
                Text(model.acceptWhenDone ? "Replacing…" : "Replace  ↵")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(green))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(model.versions.isEmpty && !model.isStreaming)
            .opacity(model.versions.isEmpty && !model.isStreaming ? 0.45 : 1)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

/// The panel you get from the shortcut: rewrite the sentence you just finished (or the
/// selection, paragraph, whole field), iterate with one-key actions, Enter to put it back.
final class RefineController {
    private let panel = FloatingPanel(keyable: true, level: .floating)
    private let model = RefineModel()
    private let client: ClaudeClient
    private let settings: AppSettings
    private let tracker: FocusTracker
    private var snapshot: FieldSnapshot?
    private var range: NSRange?
    private var context = ""
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var anchor: CGRect?
    private var placedAbove = false
    private var sizeObserver: AnyCancellable?

    /// Test hook: accept automatically once the first rewrite finishes.
    var autoAcceptNext = false
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onAccept: ((FieldSnapshot, NSRange, String, String) -> Void)?

    var isOpen: Bool { panel.isVisible }

    init(client: ClaudeClient, settings: AppSettings, tracker: FocusTracker) {
        self.client = client
        self.settings = settings
        self.tracker = tracker
        panel.isMovableByWindowBackground = true
        let view = RefineView(
            model: model,
            onAction: { [weak self] in self?.run($0) },
            onScope: { [weak self] in self?.setScope($0) },
            onAccept: { [weak self] in self?.accept() },
            onInstruction: { [weak self] in self?.runInstruction() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        panel.contentView = hosting
        // Size the panel to SwiftUI's ideal size whenever the content changes.
        sizeObserver = model.objectWillChange.sink { [weak self, weak hosting] in
            DispatchQueue.main.async {
                guard let self, let hosting, self.panel.isVisible else { return }
                self.resize(to: hosting.fittingSize)
            }
        }
    }

    func present(snapshot: FieldSnapshot, scope: RefineScope) {
        if isOpen { close() }
        self.snapshot = snapshot
        model.scope = scope
        model.instruction = ""
        model.showDiff = true
        model.modelLabel = settings.refineModel.shortLabel
        guard loadTarget() else {
            Toast.show("Nothing to refine here yet.")
            return
        }
        onOpen?()
        tracker.rect(for: range!, in: snapshot) { [weak self] rect in
            guard let self else { return }
            self.anchor = (rect ?? snapshot.visible).isEmpty ? nil : ScreenGeometry.toCocoa(rect ?? snapshot.visible)
            self.place(size: self.panel.contentView?.fittingSize ?? CGSize(width: 540, height: 240))
            self.panel.makeKeyAndOrderFront(nil)
            if let field = Self.firstTextField(in: self.panel.contentView) { self.panel.makeFirstResponder(field) }
            self.installMonitors()
            self.run(.improve)
            if self.autoAcceptNext {
                self.autoAcceptNext = false
                self.model.acceptWhenDone = true
            }
        }
    }

    /// Recomputes what's being refined for the current scope and starts over.
    private func loadTarget() -> Bool {
        guard let snap = snapshot,
              let r = TextTargets.refineRange(in: snap.text, selection: snap.selection, scope: model.scope), r.length > 0 else { return false }
        range = r
        model.original = (snap.text as NSString).substring(with: r)
        model.versions = []
        model.error = nil
        model.lastRunUnchanged = false
        context = model.scope == .all ? "" : TextTargets.context(around: r, in: snap.text)
        return true
    }

    private func setScope(_ scope: RefineScope) {
        guard scope != model.scope else { return }
        let previous = model.scope
        model.scope = scope
        if loadTarget() {
            run(.improve)
        } else {
            model.scope = previous
            _ = loadTarget()
        }
    }

    private func cycleScope() {
        let all = RefineScope.allCases
        setScope(all[(all.firstIndex(of: model.scope)! + 1) % all.count])
    }

    func run(_ action: RefineAction) {
        task?.cancel()
        let base = model.latest
        let started = Date()
        let id = UUID()
        runID = id
        model.running = action
        model.streamingText = ""
        model.error = nil
        model.firstTokenMs = nil
        model.lastRunUnchanged = false
        let refineModel = settings.refineModel
        model.modelLabel = refineModel.shortLabel
        let context = self.context
        task = Task { [weak self, client] in
            do {
                let result = try await client.refine(text: base, context: context, instruction: action.instruction, model: refineModel) { partial in
                    DispatchQueue.main.async {
                        guard let self, self.runID == id else { return }
                        if self.model.firstTokenMs == nil, !partial.isEmpty {
                            self.model.firstTokenMs = Int(Date().timeIntervalSince(started) * 1000)
                        }
                        self.model.streamingText = partial
                    }
                }
                await MainActor.run {
                    guard let self, self.runID == id else { return }
                    self.finish(Self.clean(result), base: base, ms: Int(Date().timeIntervalSince(started) * 1000))
                }
            } catch {
                await MainActor.run {
                    guard let self, self.runID == id, !(error is CancellationError) else { return }
                    if (error as? URLError)?.code == .cancelled { return }
                    self.model.streamingText = nil
                    self.model.running = nil
                    self.model.acceptWhenDone = false
                    self.model.error = error.localizedDescription
                }
            }
        }
    }

    private func finish(_ text: String, base: String, ms: Int) {
        model.streamingText = nil
        model.running = nil
        model.totalMs = ms
        if text.isEmpty || text == base {
            model.lastRunUnchanged = true
            // Even "no change" is an answer you can accept.
            if model.versions.isEmpty { model.versions.append(base) }
        } else {
            model.versions.append(text)
        }
        Log.info("refine (\(model.modelLabel)) done in \(ms) ms (first word \(model.firstTokenMs ?? -1) ms)")
        if model.acceptWhenDone { accept() }
    }

    private static func firstTextField(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSTextField { return view }
        for sub in view.subviews { if let f = firstTextField(in: sub) { return f } }
        return nil
    }

    /// Models sometimes wrap the answer in tags or quotes; strip them.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["text", "rewrite", "result"] where t.hasPrefix("<\(tag)>") && t.hasSuffix("</\(tag)>") {
            t = String(t.dropFirst(tag.count + 2).dropLast(tag.count + 3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private func runInstruction() {
        let text = model.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.instruction = ""
        run(.custom(text))
    }

    private func undo() {
        guard !model.versions.isEmpty, !model.isStreaming else { return }
        model.versions.removeLast()
        model.lastRunUnchanged = false
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.latest, forType: .string)
        Toast.show("Copied", near: CGPoint(x: panel.frame.midX, y: panel.frame.minY))
    }

    func accept() {
        if model.isStreaming {
            model.acceptWhenDone = true
            return
        }
        guard let snap = snapshot, let range else { close(); return }
        let original = model.original
        let final = model.latest
        close()
        guard final != original else { return }
        onAccept?(snap, range, original, final)
    }

    func close() {
        task?.cancel()
        runID = UUID()
        model.streamingText = nil
        model.running = nil
        model.acceptWhenDone = false
        removeMonitors()
        panel.orderOut(nil)
        onClose?()
    }

    // MARK: Layout

    private func place(size: CGSize) {
        let screen = (anchor.flatMap { ScreenGeometry.screen(containing: $0) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let a = anchor ?? CGRect(x: screen.midX - size.width / 2, y: screen.midY + size.height / 2, width: 0, height: 0)
        var origin = CGPoint(x: a.minX - 14, y: a.minY - 10 - size.height)
        placedAbove = origin.y < screen.minY + 8
        if placedAbove { origin.y = a.maxY + 10 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// Grows downward when below the text, upward when above, so the text stays visible.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, panel.frame.size != size else { return }
        var frame = panel.frame
        if !placedAbove { frame.origin.y = frame.maxY - size.height }
        frame.size = size
        if let screen = panel.screen?.visibleFrame, frame.minY < screen.minY + 8 {
            frame.origin.y = screen.minY + 8
        }
        panel.setFrame(frame, display: true)
    }

    // MARK: Keys

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handleKey(e)
        }
        // Clicking anywhere else dismisses, like a popover.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        let cmd = e.modifierFlags.contains(.command)
        let instructionEmpty = model.instruction.trimmingCharacters(in: .whitespaces).isEmpty
        switch e.keyCode {
        case 53:  // esc
            close(); return nil
        case 36, 76:  // return, keypad enter
            if cmd || instructionEmpty { accept() } else { runInstruction() }
            return nil
        case 48:  // tab
            cycleScope(); return nil
        default:
            break
        }
        guard cmd, let ch = e.charactersIgnoringModifiers?.lowercased() else { return e }
        if let n = Int(ch), (1...RefineAction.all.count).contains(n) {
            run(RefineAction.all[n - 1]); return nil
        }
        switch ch {
        case "z" where instructionEmpty: undo(); return nil
        case "c" where instructionEmpty: copy(); return nil
        case "d": model.showDiff.toggle(); return nil
        case "w": close(); return nil
        default: return e
        }
    }
}
