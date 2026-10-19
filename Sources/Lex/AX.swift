import AppKit
import ApplicationServices

/// Thin wrappers over the Accessibility C API. All calls are synchronous IPC to the
/// target app, so they run on FocusTracker's queue, never on the main thread.
enum AX {
    static let systemWide = AXUIElementCreateSystemWide()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    static func int(_ el: AXUIElement, _ attr: String) -> Int? {
        (value(el, attr) as? NSNumber)?.intValue
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func range(_ el: AXUIElement, _ attr: String) -> NSRange? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    /// Element frame in AX screen coordinates (origin top-left of the primary display).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), let s = value(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Screen rect of a text range, in AX coordinates.
    static func bounds(for range: NSRange, in el: AXUIElement) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, param, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.width >= 0.5, rect.height >= 1 else { return nil }
        return rect
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func setSelectedRange(_ el: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setSelectedText(_ el: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }

    static func focusedElement(inApp pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return element(app, kAXFocusedUIElementAttribute) ?? element(systemWide, kAXFocusedUIElementAttribute)
    }

    /// Chromium and Electron only build their accessibility tree when an assistive app asks.
    static func enableAccessibilityTree(pid: pid_t, chromiumBrowser: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromiumBrowser {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}

/// AX/CoreGraphics coordinates have their origin at the top-left of the primary display;
/// AppKit's at the bottom-left.
enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing r: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(r) } ?? NSScreen.main
    }
}

/// Chromium-based apps (Dia, Electron) sometimes return nothing for AXBoundsForRange but
/// support WebKit-style text markers. These helpers reach the marker functions that
/// HIServices exports without declaring in its headers.
enum TextMarkers {
    private typealias CopyMarker = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
    private static let copyStart: CopyMarker? = symbol("AXTextMarkerRangeCopyStartMarker")
    private static let copyEnd: CopyMarker? = symbol("AXTextMarkerRangeCopyEndMarker")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func start(of range: CFTypeRef) -> CFTypeRef? { copyStart?(range)?.takeRetainedValue() }
    static func end(of range: CFTypeRef) -> CFTypeRef? { copyEnd?(range)?.takeRetainedValue() }

    static func param(_ el: AXUIElement, _ attr: String, _ p: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, p, &v) == .success ? v : nil
    }

    static func fullRange(of el: AXUIElement) -> CFTypeRef? { param(el, "AXTextMarkerRangeForUIElement", el) }

    static func range(_ a: CFTypeRef, _ b: CFTypeRef, in el: AXUIElement) -> CFTypeRef? {
        param(el, "AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray)
    }

    static func length(of range: CFTypeRef, in el: AXUIElement) -> Int? {
        (param(el, "AXLengthForTextMarkerRange", range) as? NSNumber)?.intValue
    }

    static func string(of range: CFTypeRef, in el: AXUIElement) -> String? {
        param(el, "AXStringForTextMarkerRange", range) as? String
    }

    static func bounds(of range: CFTypeRef, in el: AXUIElement) -> CGRect? {
        guard let v = param(el, "AXBoundsForTextMarkerRange", range), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.width >= 0.5, rect.height >= 1 else { return nil }
        return rect
    }

    static func rightWord(from marker: CFTypeRef, in el: AXUIElement) -> CFTypeRef? {
        param(el, "AXRightWordTextMarkerRangeForTextMarker", marker)
    }
}

/// Maps character offsets in a field to text markers at word boundaries, by walking the
/// field word by word once per text version. Lets us place underlines where only the
/// marker API works.
final class MarkerMap {
    let element: AXUIElement
    let text: String
    private let origin: CFTypeRef
    private(set) var boundaries: [Int: CFTypeRef] = [:]
    private var cursor: CFTypeRef
    private var cursorOffset = 0
    private var exhausted = false
    /// False when the marker text didn't line up with the field's value; don't trust it then.
    private(set) var trustworthy = true

    init?(element: AXUIElement, text: String) {
        guard let full = TextMarkers.fullRange(of: element), let start = TextMarkers.start(of: full) else { return nil }
        self.element = element
        self.text = text
        origin = start
        cursor = start
        boundaries[0] = start
    }

    /// Walks forward until offsets up to `offset` are mapped (bounded by `maxSteps` words).
    func extend(to offset: Int, maxSteps: Int = 600) {
        var steps = 0
        while !exhausted, cursorOffset < offset, steps < maxSteps {
            steps += 1
            guard let word = TextMarkers.rightWord(from: cursor, in: element),
                  let ws = TextMarkers.start(of: word), let we = TextMarkers.end(of: word),
                  let endRange = TextMarkers.range(origin, we, in: element),
                  let endOffset = TextMarkers.length(of: endRange, in: element),
                  endOffset > cursorOffset else { exhausted = true; break }
            if let startRange = TextMarkers.range(origin, ws, in: element),
               let startOffset = TextMarkers.length(of: startRange, in: element) {
                boundaries[startOffset] = ws
                if boundaries.count == 3, let w = TextMarkers.range(ws, we, in: element),
                   let s = TextMarkers.string(of: w, in: element) {
                    // Sanity check on the first word: marker offsets must match the value's.
                    let ns = text as NSString
                    let expected = NSRange(location: startOffset, length: endOffset - startOffset)
                    trustworthy = expected.end <= ns.length && ns.substring(with: expected) == s
                }
            }
            boundaries[endOffset] = we
            cursor = we
            cursorOffset = endOffset
        }
    }

    /// Screen rect for a character range, snapped to the nearest mapped word boundaries.
    func bounds(for range: NSRange) -> CGRect? {
        extend(to: range.end)
        guard trustworthy else { return nil }
        let offsets = boundaries.keys
        guard let a = offsets.filter({ $0 <= range.location }).max(),
              let b = offsets.filter({ $0 >= range.end }).min() ?? offsets.filter({ $0 > a }).max(),
              b > a, let ma = boundaries[a], let mb = boundaries[b],
              let r = TextMarkers.range(ma, mb, in: element) else { return nil }
        return TextMarkers.bounds(of: r, in: element)
    }
}

/// Last-resort geometry: some Chromium fields (Dia) give no rects for text at all, but do
/// answer "which character is at this point?". Binary-search that to find a word's line,
/// then its left and right edges. About 30–40 lookups per word; callers cache the result.
enum HitTest {
    static func index(at p: CGPoint, in el: AXUIElement) -> Int? {
        var point = p
        guard let v = AXValueCreate(.cgPoint, &point),
              let r = TextMarkers.param(el, "AXRangeForPosition", v), CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        return AXValueGetValue(r as! AXValue, .cfRange, &cf) ? cf.location : nil
    }

    /// Rect (AX coordinates) of `range`, assumed to sit on one line, within `area`.
    /// Returns nil rather than guess when lookups disagree (right-to-left text, odd layouts).
    static func bounds(for range: NSRange, in el: AXUIElement, area: CGRect) -> CGRect? {
        guard area.width > 8, area.height > 4, range.length > 0 else { return nil }
        let a = range.location, b = range.end
        func idx(_ x: CGFloat, _ y: CGFloat) -> Int? { index(at: CGPoint(x: x, y: y), in: el) }
        let x0 = area.minX + 1

        // The line holding `a`: the lowest y whose line starts at or before `a`.
        var lo = area.minY + 1, hi = area.maxY - 1
        guard let first = idx(x0, lo), first <= a else { return nil }  // scrolled above the field
        var lineBottom = hi
        if let last = idx(x0, hi), last > a {
            while hi - lo > 1 {
                let mid = ((lo + hi) / 2).rounded(.down)
                guard let v = idx(x0, mid) else { return nil }
                if v <= a { lo = mid } else { hi = mid }
            }
            lineBottom = lo
        }
        guard let lineStart = idx(x0, lineBottom) else { return nil }

        // Top of that line: the smallest y that still lands on it.
        var lineTop = area.minY + 1
        if idx(x0, lineTop) != lineStart {
            lo = area.minY + 1; hi = lineBottom
            while hi - lo > 1 {
                let mid = ((lo + hi) / 2).rounded(.down)
                guard let v = idx(x0, mid) else { return nil }
                if v >= lineStart { hi = mid } else { lo = mid }
            }
            lineTop = hi
        }
        let y = (lineTop + lineBottom) / 2

        // Left-to-right only: the index must grow along the line.
        guard let left = idx(area.minX + 1, y), let right = idx(area.maxX - 1, y), right >= left else { return nil }

        /// Smallest x on the line whose character index is at least `target`.
        func firstX(atLeast target: Int) -> CGFloat? {
            var l = area.minX + 1, r = area.maxX - 1
            guard right >= target else { return nil }
            if left >= target { return l }
            while r - l > 0.75 {
                let m = (l + r) / 2
                guard let v = idx(m, y) else { return nil }
                if v >= target { r = m } else { l = m }
            }
            return r
        }
        guard let xa = firstX(atLeast: a), idx(xa + 0.5, y) == a else { return nil }
        var xb: CGFloat
        if let x = firstX(atLeast: b) {
            xb = x
        } else {
            // The word ends the line: take the last character's left edge plus an average width.
            guard let xl = firstX(atLeast: b - 1) else { return nil }
            let average = b - 1 > a ? (xl - xa) / CGFloat(b - 1 - a) : (lineBottom - lineTop) * 0.5
            xb = xl + max(average, 4)
        }
        guard xb > xa else { return nil }
        return CGRect(x: xa, y: lineTop, width: xb - xa, height: max(lineBottom - lineTop, 8))
    }
}

/// Rich editors (ProseMirror, Slate, Lex.js) inside Electron often can't place a range of
/// their own text, while the static-text runs inside them can. Maps the field's character
/// offsets onto those runs so each word is asked of the run that holds it.
final class LeafMap {
    struct Leaf {
        let element: AXUIElement
        let start: Int
        let length: Int
    }

    let element: AXUIElement
    let text: String
    private(set) var leaves: [Leaf] = []

    init?(element: AXUIElement, text: String, maxNodes: Int = 400) {
        self.element = element
        self.text = text
        // Editors keep a typed trailing space as a no-break space; treat the two as equal.
        // Same UTF-16 length, so offsets are unaffected.
        let ns = Self.normalized(text) as NSString
        var cursor = 0
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard visited < maxNodes, depth < 14 else { return }
            visited += 1
            if AX.string(el, kAXRoleAttribute) == "AXStaticText" {
                guard let raw = AX.string(el, kAXValueAttribute), !raw.isEmpty, cursor < ns.length else { return }
                let value = Self.normalized(raw)
                let found = ns.range(of: value, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                // Runs follow each other, separated by at most a line break or two.
                if found.location != NSNotFound, found.location - cursor <= 2 {
                    leaves.append(Leaf(element: el, start: found.location, length: found.length))
                    cursor = found.end
                }
                return
            }
            for child in (AX.value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        for child in (AX.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: 1) }
        guard !leaves.isEmpty else { return nil }
    }

    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func bounds(for range: NSRange) -> CGRect? {
        guard let leaf = leaf(containing: range) else { return nil }
        return AX.bounds(for: NSRange(location: range.location - leaf.start, length: range.length), in: leaf.element)
    }

    private func leaf(containing range: NSRange) -> Leaf? {
        leaves.first(where: { $0.start <= range.location && range.end <= $0.start + $0.length })
    }

    /// For apps that give a text run's frame but no character positions (Dia): measure the
    /// text before the word and scale it so the whole run's measured width matches its real
    /// width. Font-size differences cancel out; only single-line runs qualify.
    func measuredBounds(for range: NSRange) -> CGRect? {
        guard let leaf = leaf(containing: range), let frame = AX.frame(leaf.element),
              frame.height > 6, frame.height <= 32, frame.width > 4 else { return nil }
        let run = (text as NSString).substring(with: NSRange(location: leaf.start, length: leaf.length)) as NSString
        let font = NSFont.systemFont(ofSize: max(10, frame.height * 0.78))
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let rendered = run.trimmingCharacters(in: .whitespaces)
        let total = width(rendered)
        guard total > 0 else { return nil }
        let scale = frame.width / total
        let lead = run.length - (run as String).drop(while: { $0 == " " }).utf16.count  // leading spaces don't render
        let localStart = max(range.location - leaf.start - lead, 0)
        let localEnd = max(range.end - leaf.start - lead, localStart)
        let r = rendered as NSString
        guard localEnd <= r.length else { return nil }
        let x0 = width(r.substring(to: localStart)) * scale
        let x1 = width(r.substring(to: localEnd)) * scale
        guard x1 > x0 else { return nil }
        return CGRect(x: frame.minX + x0, y: frame.minY, width: x1 - x0, height: frame.height)
    }
}
