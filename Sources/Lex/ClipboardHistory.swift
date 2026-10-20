import AppKit
import Combine
import LexCore
import SwiftUI

// MARK: Model

final class ClipboardModel: ObservableObject {
    enum Preview { case none, text(String), image(NSImage), files([String]) }

    @Published var query = ""
    @Published var shown: [ClipItem] = []
    @Published var selectedID: UUID?
    @Published var preview: Preview = .none
    @Published var total = 0
    @Published var hotkeyLabel = ""
    private var icons: [String: NSImage] = [:]

    var selected: ClipItem? { shown.first { $0.id == selectedID } }

    /// The icon of the app something was copied from.
    func icon(for appID: String?) -> NSImage? {
        guard let appID else { return nil }
        if let cached = icons[appID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[appID] = icon
        return icon
    }
}

// MARK: Controller

/// Keeps a history of what you copy, and a panel to search it and paste any entry back.
/// Copies apps mark as private (passwords, one-time codes) and copies made in password
/// managers are never kept; Lex's own clipboard use (pasting fixes, reading a selection) isn't
/// either. History stays on this Mac.
final class ClipboardController {
    let model = ClipboardModel()
    let store: ClipboardStore
    private let settings: AppSettings
    private let panel = FloatingPanel(keyable: true, level: .floating)
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var bag = Set<AnyCancellable>()
    /// Where you were when the panel opened, to paste back into.
    private var target: (pid: pid_t, element: AXUIElement?)?

    /// Lex is using the clipboard for a moment (copying a selection to read it): don't record.
    private static var lexBusyUntil = Date.distantPast
    static func ignoreChanges(for seconds: TimeInterval) { lexBusyUntil = Date().addingTimeInterval(seconds) }

    var isOpen: Bool { panel.isVisible }

    init(settings: AppSettings) {
        self.settings = settings
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.lex.app/Clipboard")
        store = ClipboardStore(directory: directory, retention: TimeInterval(max(settings.clipboardDays, 1)) * 86400)
        let view = ClipboardView(model: model,
                                 onPaste: { [weak self] item, plain in self?.paste(item, plain: plain) },
                                 onPin: { [weak self] item in self?.togglePin(item) },
                                 onDelete: { [weak self] item in self?.delete(item) })
        panel.contentView = FirstMouseHostingView(rootView: view)
        model.$query.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(keepSelection: false) }
        }.store(in: &bag)
        model.$selectedID.removeDuplicates().sink { [weak self] id in
            DispatchQueue.main.async { self?.loadPreview(id) }
        }.store(in: &bag)
    }

    func start() {
        store.load()
        lastChange = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("clipboard history: \(store.items.count) entries")
    }

    func settingsChanged() {
        store.retention = TimeInterval(max(settings.clipboardDays, 1)) * 86400
        store.prune()
        if isOpen { refresh(keepSelection: true) }
    }

    func clear() {
        store.clear()
        if isOpen { refresh(keepSelection: false) }
    }

    // MARK: Watching

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard settings.clipboardEnabled, Date() >= Self.lexBusyUntil else { return }
        let items = pb.pasteboardItems ?? []
        let types = items.flatMap { $0.types.map(\.rawValue) }
        let front = NSWorkspace.shared.frontmostApplication
        guard ClipPolicy.shouldRecord(types: types, appID: front?.bundleIdentifier, ignoredApps: settings.clipboardIgnoredApps) else { return }
        var data: ClipData = []
        var bytes = 0
        for item in items {
            var kept: [String: Data] = [:]
            for type in item.types where ClipPolicy.keeps(type.rawValue) {
                guard let d = item.data(forType: type) else { continue }
                bytes += d.count
                guard bytes <= ClipPolicy.maxBytes else { Log.info("clipboard history: skipped a copy over 20 MB"); return }
                kept[type.rawValue] = d
            }
            if !kept.isEmpty { data.append(kept) }
        }
        guard store.add(data, appID: front?.bundleIdentifier, appName: front?.localizedName) != nil else { return }
        if isOpen { refresh(keepSelection: true) }
    }

    // MARK: Panel

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard settings.clipboardEnabled else {
            Toast.show("Clipboard history is off. Turn it on in Settings › Clipboard history.")
            return
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target = (app.processIdentifier, AX.focusedElement(inApp: app.processIdentifier))
        }
        poll()  // anything copied in the last moment
        model.query = ""
        model.hotkeyLabel = settings.clipboardHotkey.label
        refresh(keepSelection: false)
        let size = CGSize(width: 760, height: 470)
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.08,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        if let field = Self.firstTextField(in: panel.contentView) { panel.makeFirstResponder(field) }
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
    }

    private func refresh(keepSelection: Bool) {
        let shown = ClipboardStore.search(store.ordered, model.query)
        model.total = store.items.count
        model.shown = shown
        if !keepSelection || !shown.contains(where: { $0.id == model.selectedID }) {
            model.selectedID = shown.first?.id
        }
        loadPreview(model.selectedID)
    }

    private func loadPreview(_ id: UUID?) {
        guard let item = model.shown.first(where: { $0.id == id }) else { model.preview = .none; return }
        switch item.kind {
        case .text, .link:
            model.preview = .text(store.fullText(for: item))
        case .files:
            model.preview = .files(item.text.components(separatedBy: "\n"))
        case .image:
            let data = store.data(for: item.id)?.lazy.compactMap { $0[ClipTypes.png] ?? $0[ClipTypes.tiff] }.first
            model.preview = data.flatMap { NSImage(data: $0) }.map { .image($0) } ?? .none
        }
    }

    // MARK: Actions

    /// Puts the entry back on the clipboard (every format, or plain text) and pastes it where
    /// you were. It also moves to the top of the history.
    private func paste(_ item: ClipItem, plain: Bool) {
        guard put(item, plain: plain) else { return }
        let target = self.target
        close()
        DispatchQueue.global().async {
            if let target { Self.refocus(target) }
            usleep(60_000)
            Keys.press(0x09, flags: .maskCommand)  // ⌘V
        }
    }

    private func copy(_ item: ClipItem) {
        guard put(item, plain: false) else { return }
        close()
        Toast.show("Copied")
    }

    @discardableResult
    private func put(_ item: ClipItem, plain: Bool) -> Bool {
        guard let data = store.data(for: item.id) else {
            Toast.show("That entry couldn't be read.")
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if plain, item.kind != .image {
            pb.setString(item.kind == .files ? item.text : store.fullText(for: item), forType: .string)
        } else {
            pb.writeObjects(data.map { types -> NSPasteboardItem in
                let pasteItem = NSPasteboardItem()
                for (type, d) in types { pasteItem.setData(d, forType: NSPasteboard.PasteboardType(type)) }
                return pasteItem
            })
        }
        return true
    }

    private func togglePin(_ item: ClipItem) {
        store.togglePin(item.id)
        refresh(keepSelection: true)
    }

    private func delete(_ item: ClipItem) {
        let index = model.shown.firstIndex { $0.id == item.id } ?? 0
        store.remove(item.id)
        refresh(keepSelection: true)
        if model.selectedID == nil || !model.shown.contains(where: { $0.id == model.selectedID }) {
            model.selectedID = model.shown.isEmpty ? nil : model.shown[min(index, model.shown.count - 1)].id
        }
    }

    private func move(_ step: Int) {
        guard !model.shown.isEmpty else { return }
        let i = model.shown.firstIndex { $0.id == model.selectedID } ?? 0
        model.selectedID = model.shown[min(max(i + step, 0), model.shown.count - 1)].id
    }

    /// Back to the app and field you were in, so ⌘V lands there.
    private static func refocus(_ target: (pid: pid_t, element: AXUIElement?)) {
        DispatchQueue.main.sync { _ = NSRunningApplication(processIdentifier: target.pid)?.activate() }
        guard let element = target.element else { usleep(80_000); return }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(target.pid)
        for _ in 0..<15 {
            if let focused = AX.element(app, kAXFocusedUIElementAttribute), CFEqual(focused, element) { break }
            usleep(20_000)
        }
    }

    // MARK: Keys

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handleKey(e)
        }
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
        switch e.keyCode {
        case 53: close(); return nil                                   // esc
        case 125: move(1); return nil                                  // ↓
        case 126: move(-1); return nil                                 // ↑
        case 36, 76:                                                   // return
            if let item = model.selected { paste(item, plain: cmd) }
            return nil
        case 51 where cmd:                                             // ⌘⌫
            if let item = model.selected { delete(item) }
            return nil
        default: break
        }
        guard cmd, let ch = e.charactersIgnoringModifiers?.lowercased() else { return e }
        if let n = Int(ch), (1...9).contains(n) {
            if n <= model.shown.count { paste(model.shown[n - 1], plain: false) }
            return nil
        }
        switch ch {
        case "c":
            // Text selected in the search field copies as usual; otherwise the entry is copied.
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return e }
            if let item = model.selected { copy(item) }
            return nil
        case "p":
            if let item = model.selected { togglePin(item) }
            return nil
        case "w":
            close(); return nil
        default:
            return e
        }
    }

    private static func firstTextField(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSTextField { return view }
        for sub in view.subviews { if let f = firstTextField(in: sub) { return f } }
        return nil
    }
}

// MARK: View

struct ClipboardView: View {
    @ObservedObject var model: ClipboardModel
    let onPaste: (ClipItem, Bool) -> Void
    let onPin: (ClipItem) -> Void
    let onDelete: (ClipItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                Text("\(model.total) \(model.total == 1 ? "item" : "items")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 320)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 470)
        .panelBackground(radius: 14)
    }

    // MARK: List

    private var list: some View {
        Group {
            if model.shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.shown.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                                    .id(item.id)
                                    .onTapGesture(count: 2) { onPaste(item, false) }
                                    .onTapGesture { model.selectedID = item.id }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: 9) {
            if let icon = model.icon(for: item.appID) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: Self.symbol(item.kind)).frame(width: 18, height: 18).foregroundStyle(.secondary)
            }
            Text(Self.title(item)).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Brand.orange) }
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Brand.indigo.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if let item = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch model.preview {
                    case .text(let text):
                        ScrollView {
                            Text(text).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(14)
                        }
                    case .image(let image):
                        Image(nsImage: image).resizable().scaledToFit().padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .files(let paths):
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(paths, id: \.self) { path in
                                    HStack(spacing: 8) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                                        Text(path).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(14)
                        }
                    case .none:
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 6) {
                    Text(Self.details(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { onPin(item) } label: { Image(systemName: item.pinned ? "pin.slash" : "pin") }
                        .buttonStyle(.borderless).help(item.pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
                    Button { onDelete(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete (⌘⌫)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↵", "Paste")
            hint("⌘↵", "Paste as plain text")
            hint("⌘C", "Copy")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            Spacer()
            hint("esc", "Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 11, weight: .semibold))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Text

    static func symbol(_ kind: ClipItem.Kind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "folder"
        }
    }

    static func title(_ item: ClipItem) -> String {
        switch item.kind {
        case .image: return "Image"
        case .files:
            let names = item.text.components(separatedBy: "\n").map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        case .text, .link:
            let line = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func details(_ item: ClipItem) -> String {
        var parts: [String] = []
        if let app = item.appName { parts.append("From \(app)") }
        parts.append(relative.localizedString(for: item.date, relativeTo: Date()))
        if item.kind == .text {
            let words = item.text.split(whereSeparator: \.isWhitespace).count
            parts.append("\(words) \(words == 1 ? "word" : "words")")
        } else {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
        }
        if item.pinned { parts.append("Pinned") }
        return parts.joined(separator: " · ")
    }
}
