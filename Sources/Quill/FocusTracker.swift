import AppKit
import QuillCore

/// The focused text field in the frontmost app, as of one poll.
struct FieldSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let text: String
    let selection: NSRange
    /// AX coordinates. `visible` is `frame` clipped to the enclosing scroll area.
    let frame: CGRect
    let visible: CGRect
    /// Chromium browsers and Electron apps: edit through the editor (paste), not AX writes.
    let webBased: Bool

    var caret: Int? { selection.length == 0 ? selection.location : nil }
}

struct TrackerUpdate {
    let snapshot: FieldSnapshot?
    let elementChanged: Bool
    let textChanged: Bool
    let selectionChanged: Bool
    let geometryChanged: Bool
}

/// Polls the focused element every 100 ms on its own queue. Polling is what works across
/// Cocoa, Chromium and Electron alike; AX notifications are unreliable in web views.
final class FocusTracker {
    let queue = DispatchQueue(label: "quill.ax", qos: .userInteractive)
    var onUpdate: ((TrackerUpdate) -> Void)?

    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.chromium.Chromium", "com.openai.atlas",
    ]

    // Everything below is only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var last: FieldSnapshot?
    private var lastFullRead = Date.distantPast
    private var preparedPids = Set<pid_t>()
    private var webBasedPids = [pid_t: Bool]()
    private var scrollArea: (field: AXUIElement, area: AXUIElement?)?
    private var probeRange: NSRange?
    private var probeRect: CGRect?
    private var frontmost: (pid: pid_t, bundleID: String, url: URL?)?
    private var excluded = Set<String>()
    private var paused = false
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.setFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        setFrontmost(NSWorkspace.shared.frontmostApplication)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func setFrontmost(_ app: NSRunningApplication?) {
        let info = app.map { (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "", url: $0.bundleURL) }
        queue.async { self.frontmost = info }
    }

    func setExcluded(_ ids: [String]) { queue.async { self.excluded = Set(ids) } }
    func setPaused(_ paused: Bool) { queue.async { self.paused = paused; self.last = nil } }
    func setProbe(_ range: NSRange?) { queue.async { self.probeRange = range; self.probeRect = nil } }

    /// Reads the focused field right now (for the refine shortcut).
    func readNow(_ completion: @escaping (FieldSnapshot?) -> Void) {
        queue.async {
            let snap = self.read(reuseText: false)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    private func tick() {
        guard !paused else { return }
        let snap = read(reuseText: true)
        let prev = last
        let elementChanged: Bool
        switch (prev, snap) {
        case (nil, nil): return
        case (nil, _), (_, nil): elementChanged = true
        case let (p?, s?): elementChanged = !CFEqual(p.element, s.element)
        }
        let textChanged = elementChanged || prev?.text != snap?.text
        let selectionChanged = prev?.selection != snap?.selection
        var geometryChanged = elementChanged || prev?.frame != snap?.frame || prev?.visible != snap?.visible
        // Scrolling moves text without moving the field; watch one issue's position to catch it.
        if let snap, let probe = probeRange, probe.end <= (snap.text as NSString).length {
            let rect = AX.bounds(for: probe, in: snap.element)
            if rect != probeRect {
                if probeRect != nil { geometryChanged = true }
                probeRect = rect
            }
        }
        last = snap
        guard elementChanged || textChanged || selectionChanged || geometryChanged else { return }
        let update = TrackerUpdate(snapshot: snap, elementChanged: elementChanged, textChanged: textChanged, selectionChanged: selectionChanged, geometryChanged: geometryChanged)
        DispatchQueue.main.async { self.onUpdate?(update) }
    }

    private func read(reuseText: Bool) -> FieldSnapshot? {
        guard AX.isTrusted, let front = frontmost, front.pid != ownPid, !excluded.contains(front.bundleID) else { return nil }
        let webBased = prepare(front)
        guard let el = AX.focusedElement(inApp: front.pid), let role = AX.string(el, kAXRoleAttribute) else { return nil }
        let subrole = AX.string(el, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" || subrole == "AXSearchField" { return nil }
        let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
        guard textRoles.contains(role) || (role != "AXStaticText" && AX.isSettable(el, kAXValueAttribute)) else { return nil }

        let count = AX.int(el, kAXNumberOfCharactersAttribute)
        let selection = AX.range(el, kAXSelectedTextRangeAttribute) ?? NSRange(location: count ?? 0, length: 0)
        let text: String
        // Long documents: skip re-reading the whole value when nothing visibly changed.
        if reuseText, let last, CFEqual(last.element, el), let count, count > 4000,
           count == (last.text as NSString).length, selection == last.selection,
           Date().timeIntervalSince(lastFullRead) < 1 {
            text = last.text
        } else {
            guard let value = AX.string(el, kAXValueAttribute) else { return nil }
            text = value
            lastFullRead = Date()
        }
        guard (text as NSString).length <= 60_000 else { return nil }

        let frame = AX.frame(el) ?? .zero
        if scrollArea == nil || !CFEqual(scrollArea!.field, el) {
            scrollArea = (el, findScrollArea(above: el))
        }
        var visible = frame
        if let area = scrollArea?.area, let areaFrame = AX.frame(area) {
            let clipped = frame.intersection(areaFrame)
            visible = clipped.isNull ? .zero : clipped
        }
        return FieldSnapshot(element: el, pid: front.pid, bundleID: front.bundleID, text: text, selection: selection, frame: frame, visible: visible, webBased: webBased)
    }

    /// Turns on Chromium/Electron accessibility once per process; returns whether it's web-based.
    private func prepare(_ app: (pid: pid_t, bundleID: String, url: URL?)) -> Bool {
        if let known = webBasedPids[app.pid] { return known }
        let chromium = Self.chromiumBrowsers.contains(app.bundleID)
        let electron = app.url.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        if !preparedPids.contains(app.pid) {
            preparedPids.insert(app.pid)
            AX.enableAccessibilityTree(pid: app.pid, chromiumBrowser: chromium)
        }
        webBasedPids[app.pid] = chromium || electron
        return chromium || electron
    }

    private func findScrollArea(above el: AXUIElement) -> AXUIElement? {
        var current = el
        for _ in 0..<6 {
            guard let parent = AX.element(current, kAXParentAttribute) else { return nil }
            if AX.string(parent, kAXRoleAttribute) == "AXScrollArea" { return parent }
            current = parent
        }
        return nil
    }

    // MARK: Geometry

    /// Screen rects (AX coordinates) for each issue, one rect per visual line.
    func rects(for issues: [Issue], in snap: FieldSnapshot, completion: @escaping ([String: [CGRect]]) -> Void) {
        queue.async {
            let ns = snap.text as NSString
            let clip = snap.visible.isEmpty ? CGRect.infinite : snap.visible.insetBy(dx: -2, dy: -2)
            var out: [String: [CGRect]] = [:]
            var calls = 0
            for issue in issues.prefix(80) where issue.range.end <= ns.length {
                var rects: [CGRect] = []
                for word in Self.wordRanges(in: issue.range, of: ns) {
                    guard calls < 240 else { break }
                    calls += 1
                    // Apps without range support return giant boxes; skip those.
                    guard let r = AX.bounds(for: word, in: snap.element), r.height < 80 else { continue }
                    let visible = r.intersection(clip)
                    guard !visible.isNull, visible.height >= r.height * 0.6 else { continue }
                    rects.append(r)
                }
                if !rects.isEmpty { out[issue.id] = Self.mergeLines(rects) }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// One rect for `range` (AX coordinates), for placing panels.
    func rect(for range: NSRange, in snap: FieldSnapshot, completion: @escaping (CGRect?) -> Void) {
        queue.async {
            var r = AX.bounds(for: range, in: snap.element)
            if r == nil || r!.height > 400 {
                let lastChar = NSRange(location: max(range.end - 1, range.location), length: min(1, range.length))
                r = AX.bounds(for: lastChar, in: snap.element)
            }
            DispatchQueue.main.async { completion(r) }
        }
    }

    static func wordRanges(in range: NSRange, of ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start: Int?
        for i in range.location..<range.end {
            let c = ns.character(at: i)
            let space = c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D
            if space {
                if let s = start { out.append(NSRange(location: s, length: i - s)); start = nil }
            } else if start == nil {
                start = i
            }
        }
        if let s = start { out.append(NSRange(location: s, length: range.end - s)) }
        return out.isEmpty ? [range] : out
    }

    /// Joins word rects that sit on the same line into one underline.
    static func mergeLines(_ rects: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for r in rects.sorted(by: { ($0.minY, $0.minX) < ($1.minY, $1.minX) }) {
            if let lastRect = out.last, abs(lastRect.midY - r.midY) < r.height / 2, r.minX - lastRect.maxX < 24 {
                out[out.count - 1] = lastRect.union(r)
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: Editing

    enum ReplaceOutcome { case replaced, pasted, failed }

    func replace(in snap: FieldSnapshot, range: NSRange, original: String, with replacement: String, refocus: Bool = false, completion: @escaping (ReplaceOutcome) -> Void) {
        queue.async {
            if refocus { Self.refocus(snap) }
            let outcome = TextReplacer.replace(element: snap.element, viaPaste: snap.webBased, range: range, original: original, replacement: replacement)
            Log.info("replace via \(outcome) (\(snap.bundleID))")
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}

extension FocusTracker {
    /// Gives keyboard focus back to the field after one of our key panels was up.
    /// A paste only lands if the field's window is key again.
    static func refocus(_ snap: FieldSnapshot) {
        let app = AXUIElementCreateApplication(snap.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = AX.element(snap.element, kAXWindowAttribute) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(snap.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Wait until the app reports the field as focused again (up to ~0.4 s).
        for _ in 0..<20 {
            if let focused = AX.element(app, kAXFocusedUIElementAttribute), CFEqual(focused, snap.element) { break }
            usleep(20_000)
        }
        usleep(40_000)
    }
}

enum TextReplacer {
    /// Selects the range through AX, then either writes it through AX (Cocoa apps) or pastes
    /// (web editors, where a raw AX write would bypass the editor and get lost).
    static func replace(element el: AXUIElement, viaPaste: Bool, range: NSRange, original: String, replacement: String) -> FocusTracker.ReplaceOutcome {
        guard let text = AX.string(el, kAXValueAttribute) else { return .failed }
        let ns = text as NSString
        var target = range
        if target.end > ns.length || ns.substring(with: target) != original {
            // The text moved since we looked; find the closest copy of the original.
            guard let found = nearest(original, in: ns, to: range.location) else { return .failed }
            target = found
        }
        guard select(el, target) else { return .failed }
        if !viaPaste, AX.setSelectedText(el, replacement) {
            for _ in 0..<5 {
                usleep(15_000)
                if let now = AX.string(el, kAXValueAttribute), now != text { return .replaced }
            }
            // Reported success but nothing changed; fall back to pasting.
            guard select(el, target) else { return .failed }
        }
        return Paster.paste(replacement) ? .pasted : .failed
    }

    static func select(_ el: AXUIElement, _ r: NSRange) -> Bool {
        for attempt in 1...3 {
            AX.setSelectedRange(el, r)
            usleep(useconds_t(12_000 * attempt))
            if AX.range(el, kAXSelectedTextRangeAttribute) == r { return true }
        }
        return false
    }

    static func nearest(_ needle: String, in ns: NSString, to location: Int) -> NSRange? {
        var best: NSRange?
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: needle, options: [], range: search)
            guard r.location != NSNotFound else { break }
            if best == nil || abs(r.location - location) < abs(best!.location - location) { best = r }
            let next = r.location + 1
            guard next < ns.length else { break }
            search = NSRange(location: next, length: ns.length - next)
        }
        return best
    }
}

enum Paster {
    /// Pastes `string` into the frontmost app and puts the user's clipboard back afterwards.
    static func paste(_ string: String) -> Bool {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        // Tells clipboard managers to skip this entry.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        guard pb.writeObjects([item]) else { return false }
        let ours = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ours else { return }  // the user copied something since
            pb.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let restored = NSPasteboardItem()
                for (type, data) in pairs { restored.setData(data, forType: type) }
                return restored
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return true
    }
}
