import AppKit
import LexCore

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
    let queue = DispatchQueue(label: "lex.ax", qos: .userInteractive)
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
    private var enhancedProbed = Set<pid_t>()
    private var markerMap: MarkerMap?
    private var leafMap: LeafMap?
    private var geometry: (element: AXUIElement, mode: GeometryMode, text: String)?
    private var geometryLogged = Set<String>()
    private var hitCache: (text: String, rects: [String: CGRect]) = ("", [:])
    private var hitTestsThisPass = 0
    private var lastRejectLog = ""
    private var lastRejectTime = Date.distantPast
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

    enum Selection {
        case selected(String)            // the app reported a non-empty selection
        case caret(String, NSRange)      // a text field with nothing selected
        case secure                      // a password field: never read
        case unknown                     // no answer through Accessibility (web pages, PDFs…)
    }

    /// What's selected in the frontmost app, for reading aloud. Works in every app,
    /// including ones Lex doesn't check.
    func selection(_ completion: @escaping (Selection) -> Void) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async {
            var result = Selection.unknown
            if let pid, pid != self.ownPid, let el = AX.focusedElement(inApp: pid) {
                let role = AX.string(el, kAXRoleAttribute)
                let subrole = AX.string(el, kAXSubroleAttribute)
                if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
                    result = .secure
                } else if let selected = AX.string(el, kAXSelectedTextAttribute), !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result = .selected(selected)
                } else if let value = AX.string(el, kAXValueAttribute), !value.isEmpty,
                          let range = AX.range(el, kAXSelectedTextRangeAttribute), range.length == 0 {
                    result = .caret(value, range)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

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
        let engine = app.url.map(Self.chromiumEngine) ?? .none
        let chromium = engine == .browser || Self.chromiumBrowsers.contains(app.bundleID)
        let electron = engine == .electron
        if !preparedPids.contains(app.pid) {
            preparedPids.insert(app.pid)
            AX.enableAccessibilityTree(pid: app.pid, chromiumBrowser: chromium)
            Log.info("prepared \(app.bundleID): \(chromium ? "chromium browser" : electron ? "electron" : "native")")
        }
        webBasedPids[app.pid] = chromium || electron
        return chromium || electron
    }

    enum ChromiumEngine { case none, browser, electron }

    /// Every Chromium-based app ships a renderer helper ("… Helper (Renderer).app", or
    /// "Codex (Renderer).app"); Electron apps also ship Electron Framework. Catches apps we
    /// don't know by name (Dia, Arc, Codex…).
    static func chromiumEngine(_ url: URL) -> ChromiumEngine {
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        if fm.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) { return .electron }
        guard let walker = fm.enumerator(at: frameworks, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return .none }
        for case let item as URL in walker {
            if item.lastPathComponent.hasSuffix("(Renderer).app") { return .browser }
            if item.pathExtension == "app" || walker.level > 5 { walker.skipDescendants() }
        }
        return .none
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
            var rejected: [String: Int] = [:]
            var sample: CGRect?
            self.hitTestsThisPass = 0
            for issue in issues.prefix(80) where issue.range.end <= ns.length {
                var rects: [CGRect] = []
                for word in Self.wordRanges(in: issue.range, of: ns) {
                    guard calls < 240 else { break }
                    calls += 1
                    guard let r = self.wordBounds(word, in: snap) else { rejected["no bounds", default: 0] += 1; continue }
                    // Apps without range support return giant boxes; skip those.
                    guard r.height < 80 else { rejected["too tall", default: 0] += 1; sample = r; continue }
                    let visible = r.intersection(clip)
                    guard !visible.isNull, visible.height >= r.height * 0.6 else { rejected["outside field", default: 0] += 1; sample = r; continue }
                    rects.append(r)
                }
                if !rects.isEmpty { out[issue.id] = Self.mergeLines(rects) }
            }
            if !rejected.isEmpty {
                // Numbers only: why positions were rejected, never any text.
                let key = "\(snap.bundleID)|\(rejected.keys.sorted())"
                if key != self.lastRejectLog || Date().timeIntervalSince(self.lastRejectTime) > 30 {
                    self.lastRejectLog = key
                    self.lastRejectTime = Date()
                    Log.info("positions rejected in \(snap.bundleID): \(rejected) sample=\(sample.map { "\($0)" } ?? "-") frame=\(snap.frame) visible=\(snap.visible)")
                }
                // Debug only: once per app, try every way of finding text positions and report.
                if UserDefaults.standard.bool(forKey: "debugLog"), !self.enhancedProbed.contains(snap.pid),
                   let first = issues.first(where: { $0.range.end <= ns.length }) {
                    self.enhancedProbed.insert(snap.pid)
                    self.diagnose(snap, range: Self.wordRanges(in: first.range, of: ns)[0])
                }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    enum GeometryMode: String { case direct, leaves, markers, measured, hitTest, none }

    /// A word's screen rect. Tries AXBoundsForRange, then text markers, then hit-testing,
    /// remembering per field which one works. Must run on `queue`.
    private func wordBounds(_ range: NSRange, in snap: FieldSnapshot) -> CGRect? {
        let forced = UserDefaults.standard.string(forKey: "forceGeometry").flatMap(GeometryMode.init)  // debug
        var mode = forced
        if mode == nil, let g = geometry, CFEqual(g.element, snap.element), g.mode != .none || g.text == snap.text {
            mode = g.mode
        }
        if mode == nil {
            mode = detectGeometry(range, in: snap)
            geometry = (snap.element, mode!, snap.text)
            let key = "\(snap.bundleID):\(mode!.rawValue)"
            if !geometryLogged.contains(key) {
                geometryLogged.insert(key)
                Log.info("geometry for \(snap.bundleID): \(mode!.rawValue)")
            }
        }
        return bounds(range, in: snap, mode: mode!)
    }

    private func detectGeometry(_ range: NSRange, in snap: FieldSnapshot) -> GeometryMode {
        for mode in [GeometryMode.direct, .leaves, .markers, .measured, .hitTest] {
            if mode != .direct, !snap.webBased { break }
            if bounds(range, in: snap, mode: mode) != nil { return mode }
        }
        return .none
    }

    private func bounds(_ range: NSRange, in snap: FieldSnapshot, mode: GeometryMode) -> CGRect? {
        let rect: CGRect?
        switch mode {
        case .direct:
            rect = AX.bounds(for: range, in: snap.element)
        case .leaves:
            if leafMap == nil || !CFEqual(leafMap!.element, snap.element) || leafMap!.text != snap.text {
                leafMap = LeafMap(element: snap.element, text: snap.text)
            }
            rect = leafMap?.bounds(for: range)
        case .measured:
            if leafMap == nil || !CFEqual(leafMap!.element, snap.element) || leafMap!.text != snap.text {
                leafMap = LeafMap(element: snap.element, text: snap.text)
            }
            rect = leafMap?.measuredBounds(for: range)
        case .markers:
            if markerMap == nil || !CFEqual(markerMap!.element, snap.element) || markerMap!.text != snap.text {
                markerMap = MarkerMap(element: snap.element, text: snap.text)
            }
            rect = markerMap?.bounds(for: range)
        case .hitTest:
            let area = snap.visible.isEmpty ? snap.frame : snap.visible
            let key = "\(range.location),\(range.length)|\(area)"
            if hitCache.text != snap.text { hitCache = (snap.text, [:]) }
            if let cached = hitCache.rects[key] { return cached }
            guard hitTestsThisPass < 8 else { return nil }  // keeps a refresh fast; the rest come next pass
            hitTestsThisPass += 1
            rect = HitTest.bounds(for: range, in: snap.element, area: area)
            if let rect { hitCache.rects[key] = rect }
        case .none:
            rect = nil
        }
        guard let rect, !isWholeField(rect, range: range, in: snap) else { return nil }
        return rect
    }

    /// Some Electron fields answer every range with the whole field's box.
    private func isWholeField(_ r: CGRect, range: NSRange, in snap: FieldSnapshot) -> Bool {
        let f = snap.frame
        guard f.width > 120, range.length < 40 else { return false }
        return r.width >= f.width * 0.85
    }

    /// Debug: every route to a word's screen position, numbers only. Runs on `queue`.
    private func diagnose(_ snap: FieldSnapshot, range: NSRange) {
        let el = snap.element
        func f(_ r: CGRect?) -> String { r.map { String(format: "(%.0f,%.0f %.0fx%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? "nil" }
        var report = ["app=\(snap.bundleID) role=\(AX.string(el, kAXRoleAttribute) ?? "?") chars=\((snap.text as NSString).length) range=[\(range.location),\(range.length)] frame=\(f(snap.frame))"]
        report.append("direct=\(f(AX.bounds(for: range, in: el)))")
        // Text markers, step by step.
        let full = TextMarkers.fullRange(of: el)
        let start = full.flatMap(TextMarkers.start(of:))
        let word = start.flatMap { TextMarkers.rightWord(from: $0, in: el) }
        report.append("markers: full=\(full != nil) fullLen=\(full.flatMap { TextMarkers.length(of: $0, in: el) }.map(String.init) ?? "nil") fullBounds=\(f(full.flatMap { TextMarkers.bounds(of: $0, in: el) })) start=\(start != nil) word=\(word != nil) wordLen=\(word.flatMap { TextMarkers.length(of: $0, in: el) }.map(String.init) ?? "nil") wordBounds=\(f(word.flatMap { TextMarkers.bounds(of: $0, in: el) }))")
        // Point to index.
        var point = CGPoint(x: snap.frame.minX + 6, y: snap.frame.minY + 8)
        var hit = "nil"
        if let v = AXValueCreate(.cgPoint, &point), let r = TextMarkers.param(el, "AXRangeForPosition", v), CFGetTypeID(r) == AXValueGetTypeID() {
            var cf = CFRange(); if AXValueGetValue(r as! AXValue, .cfRange, &cf) { hit = "[\(cf.location),\(cf.length)]" }
        }
        report.append("rangeForPosition(top-left)=\(hit)")
        var hits: [String] = []
        for fx in [0.1, 0.4, 0.7, 0.95] {
            var p = CGPoint(x: snap.frame.minX + snap.frame.width * fx, y: snap.frame.midY)
            if let v = AXValueCreate(.cgPoint, &p), let r = TextMarkers.param(el, "AXRangeForPosition", v), CFGetTypeID(r) == AXValueGetTypeID() {
                var cf = CFRange(); _ = AXValueGetValue(r as! AXValue, .cfRange, &cf); hits.append("\(cf.location)")
            } else { hits.append("nil") }
        }
        report.append("rangeForPosition(across)=\(hits.joined(separator: ","))")
        if let leaves = LeafMap(element: el, text: snap.text) {
            let firstLeaf = leaves.leaves[0]
            report.append("leaves=\(leaves.leaves.count) first=[\(firstLeaf.start),\(firstLeaf.length)] frame=\(f(AX.frame(firstLeaf.element))) leafBounds=\(f(leaves.bounds(for: range)))")
        } else {
            report.append("leaves=none")
        }
        // Children and their frames.
        var kids: [String] = []
        if let children = AX.value(el, kAXChildrenAttribute) as? [AXUIElement] {
            for c in children.prefix(4) {
                let grand = (AX.value(c, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0
                kids.append("\(AX.string(c, kAXRoleAttribute) ?? "?")\(f(AX.frame(c)))+\(grand)")
            }
            report.append("children=\(children.count) \(kids.joined(separator: " "))")
        } else {
            report.append("children=none")
        }
        // Font, for measuring text ourselves.
        var font = "nil"
        var cf = CFRange(location: range.location, length: range.length)
        if let v = AXValueCreate(.cfRange, &cf), let a = TextMarkers.param(el, "AXAttributedStringForRange", v) as? NSAttributedString, a.length > 0 {
            let attrs = a.attributes(at: 0, effectiveRange: nil)
            font = attrs.keys.map(\.rawValue).sorted().joined(separator: ",")
            if let fd = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
                font += " size=\(fd["AXFontSize"] ?? "?") family=\(fd["AXFontFamily"] ?? "?")"
            }
        }
        report.append("attributes=\(font)")
        // Full accessibility mode, then try again.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(snap.pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        usleep(1_500_000)
        report.append("after enhanced: direct=\(f(AX.bounds(for: range, in: el))) wordBounds=\(f(TextMarkers.fullRange(of: el).flatMap(TextMarkers.start(of:)).flatMap { TextMarkers.rightWord(from: $0, in: el) }.flatMap { TextMarkers.bounds(of: $0, in: el) }))")
        Log.info("diagnose " + report.joined(separator: " | "))
    }

    /// Debug: for each issue, the rect from AXBoundsForRange next to the text-marker rect.
    func compareRects(for issues: [Issue], in snap: FieldSnapshot) {
        queue.async {
            let started = Date()
            let map = MarkerMap(element: snap.element, text: snap.text)
            map?.extend(to: issues.map(\.range.end).max() ?? 0)
            Log.info("compare: markers \(map.map { "\($0.boundaries.count) boundaries, trustworthy=\($0.trustworthy)" } ?? "unsupported") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            for issue in issues {
                let direct = AX.bounds(for: issue.range, in: snap.element)
                let marker = map?.bounds(for: issue.range)
                let hit = HitTest.bounds(for: issue.range, in: snap.element, area: snap.visible.isEmpty ? snap.frame : snap.visible)
                let leaves = LeafMap(element: snap.element, text: snap.text)
                let leaf = leaves?.bounds(for: issue.range)
                let measured = leaves?.measuredBounds(for: issue.range)
                func f(_ r: CGRect?) -> String { r.map { String(format: "(%.0f,%.0f %.0fx%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? "nil" }
                Log.info("compare [\(issue.range.location),\(issue.range.length)] direct=\(f(direct)) markers=\(f(marker)) leaves=\(f(leaf)) measured=\(f(measured)) hitTest=\(f(hit))")
            }
        }
    }

    /// Debug: logs what the focused field reports about its geometry. Numbers only, no text.
    /// With `enhance`, first turns on Chromium's full accessibility mode for the app.
    func probeGeometry(enhance: Bool) {
        queue.async {
            guard let snap = self.read(reuseText: false) else { Log.info("probe: no text field focused"); return }
            if enhance {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(snap.pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                usleep(600_000)
            }
            let el = AX.focusedElement(inApp: snap.pid) ?? snap.element
            let n = (snap.text as NSString).length
            var names: CFArray?
            AXUIElementCopyParameterizedAttributeNames(el, &names)
            let params = (names as? [String])?.filter { $0.contains("Range") || $0.contains("Bounds") } ?? []
            func b(_ r: NSRange) -> String { r.end <= n && r.length > 0 ? (AX.bounds(for: r, in: el).map { "\($0)" } ?? "nil") : "n/a" }
            Log.info("probe \(snap.bundleID) enhanced=\(enhance) role=\(AX.string(el, kAXRoleAttribute) ?? "?") chars=\(n) frame=\(snap.frame) visible=\(snap.visible)")
            Log.info("probe params: \(params)")
            Log.info("probe bounds first=\(b(NSRange(location: 0, length: min(1, n)))) firstWord=\(b(NSRange(location: 0, length: min(4, n)))) last=\(b(NSRange(location: max(n - 1, 0), length: min(1, n))))")
        }
    }

    /// Debug: geometry of the focused field in a given (possibly background) app.
    /// Read-only, numbers only; reports whether the field is a LEXTEST field without logging text.
    func probeApp(bundleID: String, enhance: Bool) {
        queue.async {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                Log.info("probe-app: \(bundleID) not running"); return
            }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.5)
            if enhance {
                AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                usleep(800_000)
            }
            guard let el = AX.element(appEl, kAXFocusedUIElementAttribute) else { Log.info("probe-app: no focused element"); return }
            let text = AX.string(el, kAXValueAttribute) ?? ""
            let n = (text as NSString).length
            let frame = AX.frame(el)
            let area = self.findScrollArea(above: el).flatMap(AX.frame)
            func b(_ r: NSRange) -> String { r.end <= n && r.length > 0 ? (AX.bounds(for: r, in: el).map { "\($0)" } ?? "nil") : "n/a" }
            Log.info("probe-app \(bundleID) enhanced=\(enhance) role=\(AX.string(el, kAXRoleAttribute) ?? "?") testField=\(text.hasPrefix("LEXTEST")) chars=\(n) frame=\(frame.map { "\($0)" } ?? "nil") scrollArea=\(area.map { "\($0)" } ?? "none")")
            Log.info("probe-app bounds [0,4]=\(b(NSRange(location: 0, length: 4))) [10,5]=\(b(NSRange(location: 10, length: 5))) [last]=\(b(NSRange(location: max(n - 1, 0), length: 1)))")
        }
    }

    /// One rect for `range` (AX coordinates), for placing panels.
    func rect(for range: NSRange, in snap: FieldSnapshot, completion: @escaping (CGRect?) -> Void) {
        queue.async {
            var r = AX.bounds(for: range, in: snap.element)
            if let rect = r, rect.width >= snap.frame.width * 0.85, snap.frame.width > 120 { r = nil }
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
        guard let text = AX.string(el, kAXValueAttribute) else { Log.info("refused: field value unreadable"); return .failed }
        let ns = text as NSString
        var target = range
        if target.end > ns.length || ns.substring(with: target) != original {
            // The text moved since we looked; find the closest copy of the original.
            guard let found = nearest(original, in: ns, to: range.location) else { Log.info("refused: words no longer in the field"); return .failed }
            target = found
        }
        guard select(el, target) else {
            Log.info("refused: selection didn't stick (wanted \(target), got \(AX.range(el, kAXSelectedTextRangeAttribute).map { "\($0)" } ?? "nil"))")
            return .failed
        }
        if !selectionHolds(original, in: el, logMismatch: false) {
            // Some editors (ProseMirror in Electron) count selection offsets differently from
            // the text they report. Find how far off the selection landed and shift it.
            guard let selected = AX.string(el, kAXSelectedTextAttribute),
                  let delta = offsetDelta(selected: selected, in: ns, target: target),
                  target.location - delta >= 0 else {
                _ = selectionHolds(original, in: el)  // logs the mismatch
                return .failed
            }
            let corrected = NSRange(location: target.location - delta, length: target.length)
            guard select(el, corrected), selectionHolds(original, in: el) else { return .failed }
            Log.info("selection offset corrected by \(delta)")
            target = corrected
        }
        if !viaPaste, AX.setSelectedText(el, replacement) {
            for _ in 0..<5 {
                usleep(15_000)
                if let now = AX.string(el, kAXValueAttribute), now != text { return .replaced }
            }
            // Reported success but nothing changed; fall back to pasting.
            guard select(el, target) else { return .failed }
        }
        // Last check right before pasting: still exactly our selection, still the same words.
        guard AX.range(el, kAXSelectedTextRangeAttribute) == target else { Log.info("refused: selection moved before pasting"); return .failed }
        guard selectionHolds(original, in: el) else { return .failed }
        if replacement.isEmpty {
            // Editors ignore an empty paste; a removal is a Delete keystroke on the selection.
            Keys.press(0x33)  // delete (backspace)
            return .pasted
        }
        return Paster.paste(replacement) ? .pasted : .failed
    }

    /// The app agrees the selected text is the words we mean to replace. Editors can count
    /// offsets differently from their AXValue; this stops a paste from landing elsewhere.
    static func selectionHolds(_ original: String, in el: AXUIElement, logMismatch: Bool = true) -> Bool {
        guard let selected = AX.string(el, kAXSelectedTextAttribute) else { return true }  // can't tell; range already checked
        // Editors trim edge spaces from the selected text they report; the range was already
        // checked exactly, so compare the words.
        let a = LeafMap.normalized(selected).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = LeafMap.normalized(original).trimmingCharacters(in: .whitespacesAndNewlines)
        if a != b, logMismatch { Log.info("refused: selected text differs (\((selected as NSString).length) vs \((original as NSString).length) chars)") }
        return a == b
    }

    /// How far the editor's selection landed from where we asked: the shift d for which the
    /// value's text at target+d is what got selected. Small shifts only; the caller re-checks.
    static func offsetDelta(selected: String, in ns: NSString, target: NSRange) -> Int? {
        let want = LeafMap.normalized(selected)
        for d in [1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6] {
            let r = NSRange(location: target.location + d, length: (selected as NSString).length)
            guard r.location >= 0, r.end <= ns.length else { continue }
            if LeafMap.normalized(ns.substring(with: r)) == want { return d }
        }
        return nil
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

enum Keys {
    /// Posts one key press (virtual key code) to the frontmost app, with no modifiers.
    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum Paster {
    /// Pastes `string` into the frontmost app and puts the user's clipboard back afterwards.
    static func paste(_ string: String) -> Bool {
        let pb = NSPasteboard.general
        let saved = snapshot()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        // Tells clipboard managers to skip this entry.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        guard pb.writeObjects([item]) else { return false }
        let ours = pb.changeCount

        Keys.press(0x09, flags: .maskCommand)  // ⌘V

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ours else { return }  // the user copied something since
            restore(saved)
        }
        return true
    }

    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    /// Everything on the clipboard, every type of every item.
    static func snapshot() -> Snapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    static func restore(_ saved: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let restored = NSPasteboardItem()
            for (type, data) in pairs { restored.setData(data, forType: type) }
            return restored
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
