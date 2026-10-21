import LexCore
import SwiftUI
import UIKit

/// The typing keys. UIKit rather than SwiftUI so it can follow several fingers at once (fast
/// two-thumb typing overlaps touches), give each key the gap around it, and show the letter
/// above your finger.
final class KeyGridView: UIView {
    struct Look: Equatable {
        var rows: [[KeyCap]] = []
        var shift = Shift.off
        var returnLabel = "return"
        var returnProminent = false
    }

    enum Shift: Equatable { case off, on, locked }

    var look = Look() { didSet { if look != oldValue { rebuild() } } }
    /// A key was typed. Delete fires on touch down and repeats while held; the rest on lift.
    var onKey: ((KeyAction) -> Void)?

    private var keys: [(cap: KeyCap, view: KeyView)] = []
    private var touches: [UITouch: Int] = [:]
    private let popup = KeyPopup()
    private var repeatTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let gap: CGFloat = 6
    private let rowGap: CGFloat = 11

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        addSubview(popup)
        popup.isHidden = true
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
            guard let i = key(at: touch.location(in: self)) else { continue }
            touches[touch] = i
            press(i)
            UIDevice.current.playInputClick()
            haptic.impactOccurred(intensity: 0.6)
            if keys[i].cap.action == .delete {
                onKey?(.delete)
                startRepeating()
            }
        }
    }

    override func touchesMoved(_ set: Set<UITouch>, with event: UIEvent?) {
        // Sliding a finger moves to the key under it, like the system keyboard.
        for touch in set {
            guard let old = touches[touch], keys[old].cap.action != .delete,
                  let i = key(at: touch.location(in: self)), i != old else { continue }
            release(old)
            touches[touch] = i
            press(i)
        }
    }

    override func touchesEnded(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            guard let i = touches.removeValue(forKey: touch) else { continue }
            release(i)
            if keys[i].cap.action == .delete {
                stopRepeating()
            } else {
                onKey?(keys[i].cap.action)
            }
        }
    }

    override func touchesCancelled(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            guard let i = touches.removeValue(forKey: touch) else { continue }
            release(i)
            if keys[i].cap.action == .delete { stopRepeating() }
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

    /// Held delete: a pause, then faster and faster.
    private func startRepeating() {
        stopRepeating()
        var count = 0
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                count += 1
                self?.onKey?(.delete)
                if count > 25 { self?.onKey?(.delete) }
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
        addSubview(label)
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ cap: KeyCap, look: KeyGridView.Look) {
        dim = !cap.isCharacter && cap.action != .space
        prominent = false
        icon.image = nil
        label.text = nil
        switch cap.action {
        case .character(let c):
            title = look.shift == .off ? c : c.uppercased()
            label.text = title
            label.font = .systemFont(ofSize: title.count > 1 ? 18 : 24)
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

    func show(_ text: String, above key: CGRect) {
        label.text = text
        backgroundColor = traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
        label.textColor = .label
        let width = max(key.width + 14, 48)
        frame = CGRect(x: key.midX - width / 2, y: key.minY - 58, width: width, height: 56)
        label.frame = bounds
        isHidden = false
    }
}

/// The key grid inside the SwiftUI keyboard.
struct KeyGrid: UIViewRepresentable {
    let look: KeyGridView.Look
    let onKey: (KeyAction) -> Void

    func makeUIView(context: Context) -> KeyGridView {
        let view = KeyGridView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ view: KeyGridView, context: Context) {
        view.onKey = onKey
        view.look = look
    }
}
