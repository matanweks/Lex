import LexCore
import SwiftUI
import UIKit

/// The Lex keyboard. You switch to it with 🌐 when you want help with what you wrote: it
/// fixes, rewrites or translates the selection, or the paragraph before the cursor, and puts
/// the result back in place. It also dictates (through the app, see `VoiceLink`), types your
/// snippets and what you copied, and drafts a reply to a message you copied.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model, run: model.run, controller: self))
        host.view.backgroundColor = .clear
        // The keyboard's own area: no safe-area insets pushing content under its top edge.
        host.safeAreaRegions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 300)
        height.priority = .defaultHigh
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appeared(fullAccess: hasFullAccess)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.disappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) { model.refresh() }
    override func selectionDidChange(_ textInput: UITextInput?) { model.refresh() }

    // MARK: The field, through the text proxy

    var selected: String? { textDocumentProxy.selectedText }
    var before: String { textDocumentProxy.documentContextBeforeInput ?? "" }

    func type(_ text: String) { textDocumentProxy.insertText(text) }

    /// Deletes `count` characters before the cursor, one at a time (a keyboard can't select).
    func deleteBackward(_ count: Int = 1) {
        for _ in 0..<count { textDocumentProxy.deleteBackward() }
    }

    /// Opens the Lex app. Keyboards have no API for that, so this asks the app object at the
    /// end of the responder chain directly (fine for a personal build; not App Store safe).
    func openApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}

/// What the keyboard shows and does.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Tab: String, CaseIterable { case lex = "Lex", clipboard = "Clipboard", snippets = "Snippets" }

    /// Where an action's text came from, and so where its result goes.
    enum Source { case selection, beforeCursor, clipboard }

    struct Work {
        let source: Source
        let text: TextTarget
    }

    @Published var tab = Tab.lex
    @Published private(set) var target: Work?
    @Published private(set) var notice: String?
    @Published private(set) var clips: [ClipItem] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var hasFullAccess = false
    @Published private(set) var hasKey = false
    @Published private(set) var canUndo = false

    /// The keyboard's mic: opening Lex to start it, listening, or finishing the text.
    enum Mic { case off, opening, listening, finishing }
    @Published private(set) var mic = Mic.off
    @Published private(set) var micText = ""
    @Published var micLanguage = UserDefaults.standard.string(forKey: "micLanguage") ?? "en" {
        didSet { UserDefaults.standard.set(micLanguage, forKey: "micLanguage") }
    }
    /// The dictation this keyboard asked for; kept across the trip to the app and back.
    private var micRequest: UUID? {
        get { UserDefaults.standard.string(forKey: "micRequest").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "micRequest") }
    }
    private var voiceListener: VoiceLink.Listener?
    private var micTimeout: Task<Void, Never>?

    let run = ActionRun()
    weak var controller: KeyboardViewController?
    private var working: Work?
    private var lastEdit: (inserted: String, original: String)?
    private var noticeTask: Task<Void, Never>?

    func appeared(fullAccess: Bool) {
        hasFullAccess = fullAccess
        refresh()
        guard fullAccess else { return }
        // Only the keyboard on screen follows the dictation: iOS can keep an earlier one
        // alive (from before the trip to Lex), and its text field is gone.
        voiceListener = VoiceLink.Listener([.changed]) { _ in
            Task { @MainActor [weak self] in self?.voiceChanged() }
        }
        // Back from the app that started the mic: pick up where it is.
        voiceChanged()
        // Lets the app's Settings show that the keyboard is set up.
        AppGroup.defaults.set(Date(), forKey: "keyboardSeen")
        hasKey = LexEngine.claude.hasKey
        snippets = Prefs.current.snippets
        saveClipboard()
        clips = ClipboardLog.store().ordered.filter { $0.kind != .image }.prefix(40).map { $0 }
    }

    /// What an action would work on right now: the selection, or the paragraph before the cursor.
    func refresh() {
        guard let controller else { return }
        if let selected = controller.selected, let text = TextTarget(selected) {
            target = Work(source: .selection, text: text)
        } else if let text = TextTarget.beforeCursor(controller.before) {
            target = Work(source: .beforeCursor, text: text)
        } else {
            target = nil
        }
        // Undo only while the last result is still right before the cursor.
        canUndo = lastEdit.map { controller.before.hasSuffix($0.inserted) } ?? false
    }

    func perform(_ action: LexAction) {
        refresh()
        guard let target else { return show("Select text, or put the cursor after what you wrote.") }
        start(action, on: target)
    }

    /// Works on the message on the clipboard (say, one you're replying to); the result is
    /// typed at the cursor.
    func performOnClipboard(_ action: LexAction) {
        guard let copied = UIPasteboard.general.string, let text = TextTarget(copied) else {
            return show("Copy the message first, then tap this.")
        }
        start(action, on: Work(source: .clipboard, text: text))
    }

    private func start(_ action: LexAction, on work: Work) {
        notice = nil
        canUndo = false
        working = work
        let context = work.source == .beforeCursor ? String(controller?.before.dropLast(work.text.original.count) ?? "") : ""
        run.start(action, on: work.text.core, context: String(context.suffix(600)))
    }

    var resultTarget: Source? { working?.source }

    /// Puts the result in: in place of its text, or at the cursor for a copied message. Checks
    /// the field still has that text first, and copies the result instead if it doesn't.
    func apply() {
        guard let working, let controller, run.phase == .done else { return }
        let new = run.output
        switch working.source {
        case .selection:
            guard controller.selected == working.text.original else { return copyInstead(new) }
            let typed = working.text.replacement(new)
            controller.type(typed)
            lastEdit = (typed, working.text.original)
        case .beforeCursor:
            guard controller.before.hasSuffix(working.text.original) else { return copyInstead(new) }
            let typed = working.text.replacement(new)
            controller.deleteBackward(working.text.original.count)
            controller.type(typed)
            lastEdit = (typed, working.text.original)
        case .clipboard:
            let typed = DictationText.spaced(new, after: controller.before.last)
            controller.type(typed)
            lastEdit = (typed, "")
        }
        canUndo = true
        close()
    }

    /// Takes the last result back out and restores what was there.
    func undo() {
        guard let lastEdit, let controller, controller.before.hasSuffix(lastEdit.inserted) else {
            canUndo = false
            return show("Can't undo: the text changed since.")
        }
        controller.deleteBackward(lastEdit.inserted.count)
        if !lastEdit.original.isEmpty { controller.type(lastEdit.original) }
        self.lastEdit = nil
        canUndo = false
        refreshSoon()
    }

    func copyResult() {
        ClipboardLog.copy(run.output)
        show("Copied")
    }

    func close() {
        run.reset()
        working = nil
        refreshSoon()
    }

    /// Types snippet or clipboard text at the cursor, with a space before it if needed.
    func type(_ text: String) {
        guard let controller else { return }
        key(DictationText.spaced(text, after: controller.before.last))
    }

    /// The space, return and delete keys. iOS doesn't report the keyboard's own typing as a
    /// text change, so the target is refreshed here.
    func key(_ text: String?) {
        guard let controller else { return }
        if let text { controller.type(text) } else { controller.deleteBackward() }
        lastEdit = nil
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func text(of item: ClipItem) -> String { ClipboardLog.store().fullText(for: item) }

    func disappeared() {
        voiceListener = nil
    }

    // MARK: Dictation

    func micTapped() {
        switch mic {
        case .off: startMic()
        case .listening:
            mic = .finishing
            VoiceLink.post(.stop)
            giveUp(after: 25, if: .finishing, "Lex didn't send the text back. Open Lex and try again.")
        case .opening: controller?.openApp(VoiceLink.listenURL)
        case .finishing: break
        }
    }

    func cancelMic() {
        VoiceLink.post(.cancel)
        micRequest = nil
        mic = .off
    }

    private func startMic() {
        guard let controller else { return }
        let request = VoiceLink.Request(language: micLanguage, before: String(controller.before.suffix(300)))
        VoiceLink.request = request
        micRequest = request.id
        micText = ""
        mic = .opening
        giveUp(after: 60, if: .opening, "The mic didn't start. Open Lex once, then try again.")
        if VoiceLink.appIsReady {
            VoiceLink.post(.start)
            // iOS may have suspended Lex anyway; then open it.
            micTimeout?.cancel()
            micTimeout = Task {
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled, mic == .opening { controller.openApp(VoiceLink.listenURL) }
            }
        } else {
            controller.openApp(VoiceLink.listenURL)
        }
    }

    /// Stops waiting if the app never answers (iOS ended it, or it couldn't start the mic).
    private func giveUp(after seconds: Double, if phase: Mic, _ message: String) {
        let id = micRequest
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard mic == phase, micRequest == id else { return }
            micRequest = nil
            mic = .off
            show(message)
        }
    }

    /// The app wrote a new state for the dictation: show the words, or type the result.
    private func voiceChanged() {
        let state = VoiceLink.state
        voiceLog.info("keyboard sees \(state?.phase.rawValue ?? "nothing", privacy: .public), mine \(state?.request == self.micRequest)")
        guard let id = micRequest, let state, state.request == id else { return }
        // Lex quit without finishing (the state outlived it).
        if state.readyUntil < Date(), state.phase == .listening || state.phase == .finishing {
            micRequest = nil
            mic = .off
            return
        }
        switch state.phase {
        case .listening:
            micTimeout?.cancel()
            mic = .listening
            micText = state.text
        case .finishing:
            mic = .finishing
            micText = state.text
        case .done:
            micRequest = nil
            mic = .off
            if !state.text.isEmpty { type(state.text) }
        case .failed:
            micRequest = nil
            mic = .off
            show(state.error ?? "Dictation didn't work.")
        case .ready:
            micRequest = nil
            mic = .off
        }
    }

    private func copyInstead(_ new: String) {
        ClipboardLog.copy(new)
        close()
        show("The text changed, so Lex copied the result instead.")
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Saves what's on the clipboard to the history, if it's new (iPhone apps can't watch it).
    private func saveClipboard() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != ClipboardLog.seenChangeCount, AppGroup.defaults.object(forKey: "clipboardOnOpen") as? Bool ?? true else { return }
        ClipboardLog.seenChangeCount = pasteboard.changeCount
        guard pasteboard.hasStrings, ClipPolicy.shouldRecord(types: pasteboard.types, appID: nil, ignoredApps: []),
              let text = pasteboard.string else { return }
        ClipboardLog.store().add(ClipboardLog.data(text: text), appID: nil, appName: nil)
    }
}
