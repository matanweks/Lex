import LexCore
import SwiftUI
import UIKit

/// The typing keys. UIKit rather than SwiftUI so it can follow several fingers at once (fast
/// two-thumb typing overlaps touches), give each key the gap around it, and show the letter
/// above your finger. Like Gboard: hold a key for its digit and accents, slide along the
/// space bar to move the cursor, and hold or swipe left on delete to remove whole words.
final class KeyGridView: UIView {
    struct Look: Equatable {
        var rows: [[KeyCap]] = []
        var shift = Shift.off
        var returnLabel = "return"
        var returnProminent = false
        var language = KeyboardLanguage.english
    }

    enum Shift: Equatable { case off, on, locked }

    var look = Look() { didSet { if look != oldValue { rebuild() } } }
    /// A key was typed. Delete fires on touch down and repeats while held; the rest on lift.
    var onKey: ((KeyAction) -> Void)?
    /// A long-press alternate was chosen.
    var onText: ((String) -> Void)?
    /// Sliding on the space bar: move the cursor by this many characters.
    var onCursor: ((Int) -> Void)?
    /// Delete held long enough, or swiped left: remove this many words.
    var onDeleteWords: ((Int) -> Void)?

    private struct Press {
        enum Mode { case tap, alternates([String], Int), cursor(Int), deleteWords(Int) }
        var key: Int
        let start: CGPoint
        var mode = Mode.tap
    }

    private var keys: [(cap: KeyCap, view: KeyView)] = []
    private var presses: [UITouch: Press] = [:]
    private let popup = KeyPopup()
    private let choices = AlternatesPopup()
    private var holdTimer: Timer?
    private var repeatTimer: Timer?
    private let selection = UISelectionFeedbackGenerator()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let gap: CGFloat = 6
    private let rowGap: CGFloat = 11

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        addSubview(popup)
        addSubview(choices)
        popup.isHidden = true
        choices.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func rebuild() {
        if keys.map(\.cap) != look.rows.flatMap({ $0 }) {
            keys.forEach { $0.view.removeFromSuperview() }
            keys = look.rows.flatMap { $0 }.map { ($0, KeyView()) }
            keys.forEach { insertSubview($0.view, belowSubview: popup) }
        }
        for (cap, view) in keys { view.show(cap, look: look) }
        // Lay the new keys out now, so a tap right after a layout switch lands on them.
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rows = look.rows
        guard !rows.isEmpty, bounds.width > 0 else { return }
        let unit = (bounds.width - gap * (KeyboardLayout.unitsPerRow - 1) - 6) / KeyboardLayout.unitsPerRow
        let height = (bounds.height - rowGap * CGFloat(rows.count - 1) - 6) / CGFloat(rows.count)
        var i = 0
        for (r, row) in rows.enumerated() {
            let width = row.reduce(0) { $0 + CGFloat($1.width) * unit } + gap * CGFloat(row.count - 1)
            var x = (bounds.width - width) / 2
            let y = 3 + CGFloat(r) * (height + rowGap)
            for cap in row {
                let w = CGFloat(cap.width) * unit
                keys[i].view.frame = CGRect(x: x, y: y, width: w, height: height)
                x += w + gap
                i += 1
            }
        }
    }

    /// The key a touch belongs to: the row band it's in, then the nearest key in that row,
    /// so the gaps and edges type the closest key instead of nothing.
    private func key(at point: CGPoint) -> Int? {
        var best: Int?
        var bestRow = CGFloat.infinity
        var bestX = CGFloat.infinity
        for (i, key) in keys.enumerated() {
            let frame = key.view.frame
            let dy = abs(frame.midY - point.y)
            let dx = max(0, abs(frame.midX - point.x) - frame.width / 2)  // 0 on the key itself
            if dy < bestRow - 1 || (abs(dy - bestRow) <= 1 && dx < bestX) {
                best = i
                bestRow = dy
                bestX = dx
            }
        }
        return best
    }

    // MARK: Touches

    override func touchesBegan(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            let point = touch.location(in: self)
            guard let i = key(at: point) else { continue }
            presses[touch] = Press(key: i, start: point)
            press(i)
            UIDevice.current.playInputClick()
            haptic.impactOccurred(intensity: 0.6)
            if keys[i].cap.action == .delete {
                onKey?(.delete)
                startRepeating()
            }
            if case .character(let c) = keys[i].cap.action {
                let shown = look.shift == .off ? c : c.uppercased()
                let options = KeyAlternates.alternates(for: shown, look.language)
                if !options.isEmpty { holdForAlternates(touch, key: i, options: options) }
            }
        }
    }

    override func touchesMoved(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            guard var p = presses[touch] else { continue }
            let point = touch.location(in: self)
            switch p.mode {
            case .alternates(let options, let chosen):
                let pick = choices.index(at: convert(point, to: choices), count: options.count)
                if pick != chosen {
                    choices.select(pick)
                    selection.selectionChanged()
                    p.mode = .alternates(options, pick)
                }
            case .cursor(let moved):
                let steps = Int((point.x - p.start.x) / 9)
                if steps != moved {
                    onCursor?(steps - moved)
                    selection.selectionChanged()
                    p.mode = .cursor(steps)
                }
            case .deleteWords(let words):
                let count = 1 + Int(max(0, p.start.x - point.x - 24) / 30)
                if count != words {
                    popup.show(count == 1 ? "1 word" : "\(count) words", above: keys[p.key].view.frame, small: true)
                    selection.selectionChanged()
                    p.mode = .deleteWords(count)
                }
            case .tap:
                let action = keys[p.key].cap.action
                if action == .space, abs(point.x - p.start.x) > 14 {
                    // Gboard's cursor slide.
                    cancelHold()
                    keys[p.key].view.pressed = false
                    p.mode = .cursor(0)
                } else if action == .delete, p.start.x - point.x > 24 {
                    stopRepeating()
                    popup.show("1 word", above: keys[p.key].view.frame, small: true)
                    p.mode = .deleteWords(1)
                } else if action != .delete, action != .space, let i = key(at: point), i != p.key {
                    // Sliding a finger moves to the key under it, like the system keyboard.
                    cancelHold()
                    release(p.key)
                    p.key = i
                    press(i)
                }
            }
            presses[touch] = p
        }
    }

    override func touchesEnded(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            guard let p = presses.removeValue(forKey: touch) else { continue }
            release(p.key)
            cancelHold()
            switch p.mode {
            case .alternates(let options, let chosen):
                choices.isHidden = true
                onText?(options[chosen])
            case .cursor:
                break
            case .deleteWords(let words):
                onDeleteWords?(words)
            case .tap:
                if keys[p.key].cap.action == .delete {
                    stopRepeating()
                } else {
                    onKey?(keys[p.key].cap.action)
                }
            }
        }
    }

    override func touchesCancelled(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            guard let p = presses.removeValue(forKey: touch) else { continue }
            release(p.key)
            cancelHold()
            choices.isHidden = true
            if keys[p.key].cap.action == .delete { stopRepeating() }
        }
    }

    private func press(_ i: Int) {
        keys[i].view.pressed = true
        guard keys[i].cap.isCharacter, keys[i].cap.label != " " else { return }
        popup.show(keys[i].view.title, above: keys[i].view.frame)
    }

    private func release(_ i: Int) {
        keys[i].view.pressed = false
        popup.isHidden = true
    }

    /// Holding a key shows its digit and accents; the first is picked unless you slide.
    private func holdForAlternates(_ touch: UITouch, key i: Int, options: [String]) {
        cancelHold()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            guard let self, var p = self.presses[touch], p.key == i, case .tap = p.mode else { return }
            self.popup.isHidden = true
            self.choices.show(options, above: self.keys[i].view.frame, in: self.bounds)
            self.selection.selectionChanged()
            p.mode = .alternates(options, 0)
            self.presses[touch] = p
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// Held delete: a pause, then characters faster and faster, then whole words.
    private func startRepeating() {
        stopRepeating()
        var count = 0
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] timer in
                guard let self else { return }
                count += 1
                if count < 14 {
                    self.onKey?(.delete)
                } else if count % 3 == 0 {
                    self.onDeleteWords?(1)
                }
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

/// One key: a rounded cap with its label or symbol.
private final class KeyView: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    private let hint = UILabel()
    private(set) var title = ""
    private var dim = false
    private var prominent = false
    var pressed = false { didSet { paint() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .label
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .right
        addSubview(label)
        addSubview(icon)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ cap: KeyCap, look: KeyGridView.Look) {
        dim = !cap.isCharacter && cap.action != .space
        prominent = false
        icon.image = nil
        label.text = nil
        hint.text = nil
        switch cap.action {
        case .character(let c):
            title = look.shift == .off ? c : c.uppercased()
            label.text = title
            label.font = .systemFont(ofSize: title.count > 1 ? 18 : 23)
            hint.text = KeyAlternates.hint(for: c, look.language)
        case .shift:
            let name = look.shift == .locked ? "capslock.fill" : look.shift == .on ? "shift.fill" : "shift"
            icon.image = UIImage(systemName: name)
            dim = look.shift == .off
        case .delete:
            icon.image = UIImage(systemName: "delete.left")
        case .returnKey:
            prominent = look.returnProminent
            if look.returnLabel == "return" {
                icon.image = UIImage(systemName: "return")
            } else {
                label.text = look.returnLabel
                label.font = .systemFont(ofSize: 16)
            }
        case .emoji:
            icon.image = UIImage(systemName: "face.smiling")
        default:
            label.text = cap.label
            label.font = .systemFont(ofSize: 16)
        }
        label.textColor = prominent ? .white : .label
        icon.tintColor = prominent ? .white : .label
        paint()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        hint.frame = CGRect(x: 0, y: 2, width: bounds.width - 4, height: 12)
        icon.frame = bounds.insetBy(dx: bounds.width / 2 - 11, dy: bounds.height / 2 - 11)
    }

    private func paint() {
        let dark = traitCollection.userInterfaceStyle == .dark
        if prominent {
            backgroundColor = pressed ? UIColor.systemBlue.withAlphaComponent(0.7) : .systemBlue
        } else if dim != pressed {
            backgroundColor = dark ? UIColor(white: 0.27, alpha: 1) : UIColor(white: 0.68, alpha: 1)
        } else {
            backgroundColor = dark ? UIColor(white: 0.42, alpha: 1) : .white
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        paint()
    }
}

/// The enlarged letter shown above a pressed key.
private final class KeyPopup: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 34)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, above key: CGRect, small: Bool = false) {
        label.text = text
        label.font = .systemFont(ofSize: small ? 15 : 34, weight: small ? .semibold : .regular)
        backgroundColor = traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
        label.textColor = .label
        let width = small ? 90 : max(key.width + 14, 48)
        frame = CGRect(x: key.midX - width / 2, y: key.minY - 58, width: width, height: 56)
        label.frame = bounds
        isHidden = false
    }
}

/// The row of a key's alternates (its digit and accents) over a held key.
private final class AlternatesPopup: UIView {
    private var cells: [UILabel] = []
    private let cellWidth: CGFloat = 38

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ options: [String], above key: CGRect, in bounds: CGRect) {
        cells.forEach { $0.removeFromSuperview() }
        cells = options.map { option in
            let cell = UILabel()
            cell.text = option
            cell.textAlignment = .center
            cell.font = .systemFont(ofSize: 24)
            cell.layer.cornerRadius = 7
            cell.layer.masksToBounds = true
            addSubview(cell)
            return cell
        }
        backgroundColor = traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
        let width = cellWidth * CGFloat(options.count) + 8
        let x = min(max(key.midX - cellWidth / 2 - 4, bounds.minX + 2), bounds.maxX - width - 2)
        frame = CGRect(x: x, y: key.minY - 54, width: width, height: 50)
        for (i, cell) in cells.enumerated() { cell.frame = CGRect(x: 4 + CGFloat(i) * cellWidth, y: 5, width: cellWidth, height: 40) }
        select(0)
        isHidden = false
    }

    func select(_ index: Int) {
        for (i, cell) in cells.enumerated() {
            cell.backgroundColor = i == index ? UIColor(red: 0.36, green: 0.30, blue: 0.92, alpha: 1) : .clear
            cell.textColor = i == index ? .white : .label
        }
    }

    /// The option under `point` (in this view's coordinates).
    func index(at point: CGPoint, count: Int) -> Int {
        min(max(Int((point.x - 4) / cellWidth), 0), count - 1)
    }
}

/// The key grid inside the SwiftUI keyboard.
struct KeyGrid: UIViewRepresentable {
    let look: KeyGridView.Look
    let typist: Typist

    func makeUIView(context: Context) -> KeyGridView {
        let view = KeyGridView()
        wire(view)
        return view
    }

    func updateUIView(_ view: KeyGridView, context: Context) {
        wire(view)
        view.look = look
    }

    private func wire(_ view: KeyGridView) {
        view.onKey = { [typist] in typist.press($0) }
        view.onText = { [typist] in typist.typeAlternate($0) }
        view.onCursor = { [typist] in typist.moveCursor(by: $0) }
        view.onDeleteWords = { [typist] in typist.deleteWords($0) }
    }
}
