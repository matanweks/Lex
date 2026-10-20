import AppKit
import Combine
import LexCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = AppSettings()
    private lazy var client = ClaudeClient(apiKey: { [settings] in settings.apiKey() })
    private lazy var engine = Engine(settings: settings, client: client)
    private lazy var refine = RefineController(client: client, settings: settings, tracker: engine.tracker)
    private lazy var speech = SpeechClient(cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("dev.lex.app/speech"))
    private lazy var reader = Reader(settings: settings, client: speech)
    private lazy var dictation = DictationController(settings: settings, claude: client, speech: speech, tracker: engine.tracker)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var speakHotKey: HotKey?
    private var fixAllHotKey: HotKey?
    private var translateHotKey: HotKey?
    private var toneHotKey: HotKey?
    private var assistHotKey: HotKey?
    private var settingsWindow: NSWindow?
    private var trustTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private var debugHooks: DebugHooks?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        refine.onOpen = { [weak self] in self?.engine.setPaused(true) }
        refine.onClose = { [weak self] in self?.engine.setPaused(false) }
        refine.onAccept = { [weak self] snap, range, original, text in self?.write(text, over: original, at: range, in: snap) }
        engine.overlay.onBadgeClick = { [weak self] in self?.openRefine(scope: .all) }
        dictation.onCommand = { [weak self] instruction in self?.voiceEdit(instruction) }
        engine.onStatusChange = { [weak self] in self?.updateIcon() }

        settings.$hotkeyID.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotKey() }
        }.store(in: &bag)
        settings.$speakHotkeyID.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerSpeakHotKey() }
        }.store(in: &bag)
        settings.$fixAllHotkeyID.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerFixAllHotKey() }
        }.store(in: &bag)
        settings.$translateHotkeyID.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerTranslateHotKey() }
        }.store(in: &bag)
        settings.$toneHotkeyID.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerToneHotKey() }
        }.store(in: &bag)
        settings.$assistHotkeyID.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerAssistHotKey() }
        }.store(in: &bag)
        settings.$dictationKeyID.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.dictation.keyChanged() }
        }.store(in: &bag)
        DispatchQueue.global(qos: .utility).async { [speech] in speech.trimCache() }
        // Fetch the Google sign-in token now, so the first read doesn't wait for it.
        if speech.googleSignedIn { Task { [speech] in _ = try? await speech.adc.accessToken() } }
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.engine.settingsChanged()
                self?.updateIcon()
            }
        }.store(in: &bag)

        Log.info("launch: trusted=\(AX.isTrusted) key=\(settings.hasAPIKey) model=\(settings.liveModelID) refine=\(settings.refineModelID)")
        if AX.isTrusted {
            engine.start()
            dictation.start()
        } else {
            AX.promptForTrust()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AX.isTrusted else { return }
                timer.invalidate()
                self?.engine.start()
                self?.dictation.start()
                self?.updateIcon()
            }
        }
        if !settings.hasAPIKey { openSettings() }
        if settings.debugLog {
            debugHooks = DebugHooks(engine: engine, refine: refine, client: client, reader: reader, speech: speech, settings: settings) { [weak self] in self?.openRefine(scope: $0) }
            debugHooks?.dictation = dictation
            debugHooks?.appAction = { [weak self] name, arg in
                switch name {
                case "translate": self?.translate()
                case "tone": self?.toneCheck()
                case "summarize": self?.summarize()
                case "voice-edit": self?.voiceEdit(arg)
                default: break
                }
            }
            debugHooks?.install()
        }
    }

    // MARK: Fix all

    private func registerFixAllHotKey() {
        fixAllHotKey = nil
        let preset = settings.fixAllHotkey
        fixAllHotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers, id: 3) { [weak self] in
            self?.engine.fixAll()
        }
        if fixAllHotKey == nil { Log.info("couldn't register \(preset.label); another app may own it") }
    }

    @objc private func fixAllFromMenu() { engine.fixAll() }

    // MARK: Translate, tone, summarize

    private func registerTranslateHotKey() {
        translateHotKey = nil
        let preset = settings.translateHotkey
        translateHotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers, id: 4) { [weak self] in self?.translate() }
        if translateHotKey == nil { Log.info("couldn't register \(preset.label); another app may own it") }
    }

    private func registerToneHotKey() {
        toneHotKey = nil
        let preset = settings.toneHotkey
        toneHotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers, id: 5) { [weak self] in self?.toneCheck() }
        if toneHotKey == nil { Log.info("couldn't register \(preset.label); another app may own it") }
    }

    private func registerAssistHotKey() {
        assistHotKey = nil
        let preset = settings.assistHotkey
        assistHotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers, id: 6) { [weak self] in self?.summarize() }
        if assistHotKey == nil { Log.info("couldn't register \(preset.label); another app may own it") }
    }

    @objc private func translateFromMenu() { translate() }
    @objc private func toneFromMenu() { toneCheck() }
    @objc private func summarizeFromMenu() { summarize() }

    /// Hebrew to English or English to Hebrew: the selection, or the sentence you're in.
    private func translate() {
        openPanel(title: "Translate", hotkey: settings.translateHotkey) { Translation.action(for: $0) }
    }

    /// How the message you're writing will land, with a better-toned version beside it.
    private func toneCheck() {
        openPanel(title: "Tone check", hotkey: settings.toneHotkey, scope: .all) { _ in .tone }
    }

    /// Someone else's text (an email, a thread, a page): summary, key points, a reply.
    private func summarize() {
        if refine.isOpen { refine.close(); return }
        guard ready() else { return }
        TextGrabber.grab(engine.tracker, wholeField: true) { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show("Select an email or message, then press \(self.settings.assistHotkey.label).")
                return
            }
            self.refine.presentAssist(text: text, start: .summary, title: "Summarize & reply")
        }
    }

    /// Dictation over a selection: what you said is the instruction for it.
    private func voiceEdit(_ instruction: String) {
        guard ready() else { return }
        engine.tracker.readNow { [weak self] snap in
            guard let self else { return }
            if let snap, snap.selection.length > 0 {
                self.refine.present(snapshot: snap, scope: .sentence, start: .custom(instruction), title: "Voice edit")
                return
            }
            TextGrabber.grab(self.engine.tracker) { text in
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Toast.show("The selection was gone. Select the text again and say what to change.")
                    return
                }
                self.refine.presentAssist(text: text, start: .custom(instruction), title: "Voice edit")
            }
        }
    }

    /// In a field Lex can edit, works on the selection (or `scope` without one) and writes the
    /// result back. Anywhere else, works on the selected text and copies the result.
    private func openPanel(title: String, hotkey: HotkeyPreset, scope: RefineScope = .sentence, start: @escaping (String) -> RefineAction) {
        if refine.isOpen { refine.close(); return }
        guard ready() else { return }
        engine.tracker.readNow { [weak self] snap in
            guard let self else { return }
            if let snap, !snap.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let range = snap.selection.length > 0 ? snap.selection : NSRange(location: 0, length: (snap.text as NSString).length)
                let text = (snap.text as NSString).substring(with: range)
                self.refine.present(snapshot: snap, scope: snap.selection.length > 0 ? .sentence : scope, start: start(text), title: title)
                return
            }
            TextGrabber.grab(self.engine.tracker) { text in
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Toast.show("Select some text, then press \(hotkey.label).")
                    return
                }
                self.refine.presentAssist(text: text, start: start(text), title: title)
            }
        }
    }

    private func ready() -> Bool {
        guard AX.isTrusted else { AX.promptForTrust(); return false }
        guard settings.hasAPIKey else {
            openSettings()
            Toast.show("Add your Anthropic API key to use this.")
            return false
        }
        return true
    }

    // MARK: Read aloud

    private func registerSpeakHotKey() {
        speakHotKey = nil
        let preset = settings.speakHotkey
        speakHotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers, id: 2) { [weak self] in
            self?.readAloud()
        }
        if speakHotKey == nil { Log.info("couldn't register \(preset.label); another app may own it") }
    }

    @objc private func readAloudFromMenu() { readAloud() }

    @objc private func copyLastDictation() {
        guard let text = dictation.lastDictation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
    }

    /// The shortcut toggles: press to read the selection, press again to stop.
    private func readAloud() {
        if reader.isActive { reader.stop(); return }
        guard AX.isTrusted else { AX.promptForTrust(); return }
        TextGrabber.grab(engine.tracker) { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show("Select some text, then press \(self.settings.speakHotkey.label) to hear it.")
                return
            }
            self.reader.read(text)
        }
    }

    // MARK: Refine

    private func registerHotKey() {
        hotKey = nil
        let preset = settings.hotkey
        hotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.carbonModifiers) { [weak self] in
            self?.openRefine(scope: .sentence)
        }
        if hotKey == nil { Log.info("couldn't register \(preset.label); another app may own it") }
    }

    @objc private func refineFromMenu() { openRefine(scope: .sentence) }

    private func openRefine(scope: RefineScope) {
        if refine.isOpen { refine.close(); return }
        guard AX.isTrusted else { AX.promptForTrust(); return }
        guard settings.hasAPIKey else {
            openSettings()
            Toast.show("Add your Anthropic API key to refine text.")
            return
        }
        engine.tracker.readNow { [weak self] snap in
            guard let self else { return }
            guard let snap else {
                Toast.show("Click into a text field, then press \(self.settings.hotkey.label).")
                return
            }
            self.refine.present(snapshot: snap, scope: scope)
        }
    }

    /// Puts the refined text back. Waits a beat so the original app has keyboard focus again.
    private func write(_ text: String, over original: String, at range: NSRange, in snap: FieldSnapshot) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [engine] in
            engine.tracker.replace(in: snap, range: range, original: original, with: text, refocus: true) { outcome in
                if outcome == .failed {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Toast.show("This field didn't take the edit. The new text is on your clipboard.")
                }
            }
        }
    }

    // MARK: Menu

    private func updateIcon() {
        let symbol = !settings.enabled ? "pencil.slash" : (AX.isTrusted ? "pencil.line" : "exclamationmark.triangle")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lex")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !AX.isTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
        } else if !settings.hasAPIKey {
            menu.addItem(item("Add API Key…", #selector(openSettingsFromMenu)))
        }
        menu.addItem(.separator())

        let refineItem = item("Refine Text", #selector(refineFromMenu))
        refineItem.keyEquivalent = settings.hotkey.menuKey
        refineItem.keyEquivalentModifierMask = settings.hotkey.menuModifiers
        menu.addItem(refineItem)
        let fixAllItem = item("Fix All Mistakes", #selector(fixAllFromMenu))
        fixAllItem.keyEquivalent = settings.fixAllHotkey.menuKey
        fixAllItem.keyEquivalentModifierMask = settings.fixAllHotkey.menuModifiers
        menu.addItem(fixAllItem)
        for (title, action, preset) in [("Translate", #selector(translateFromMenu), settings.translateHotkey),
                                        ("Check Tone", #selector(toneFromMenu), settings.toneHotkey),
                                        ("Summarize & Reply", #selector(summarizeFromMenu), settings.assistHotkey)] {
            let i = item(title, action)
            i.keyEquivalent = preset.menuKey
            i.keyEquivalentModifierMask = preset.menuModifiers
            menu.addItem(i)
        }
        let speakItem = item(reader.isActive ? "Stop Reading" : "Read Selection Aloud", #selector(readAloudFromMenu))
        speakItem.keyEquivalent = settings.speakHotkey.menuKey
        speakItem.keyEquivalentModifierMask = settings.speakHotkey.menuModifiers
        menu.addItem(speakItem)
        if dictation.lastDictation != nil {
            menu.addItem(item("Copy Last Dictation", #selector(copyLastDictation)))
        }
        menu.addItem(item(settings.enabled ? "Pause Lex" : "Resume Lex", #selector(togglePaused)))
        if let app = engine.lastTargetApp {
            let excluded = settings.excludedApps.contains(app.bundleID)
            let toggle = item(excluded ? "Turn On in \(app.name)" : "Turn Off in \(app.name)", #selector(toggleApp))
            menu.addItem(toggle)
        }
        menu.addItem(.separator())
        let settingsItem = item("Settings…", #selector(openSettingsFromMenu))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit Lex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func statusLine() -> String {
        if !AX.isTrusted { return "Needs Accessibility access" }
        if !settings.enabled { return "Paused" }
        if !settings.hasAPIKey { return "Spelling only: add an API key for Claude" }
        if let error = engine.lastError { return "Claude: \(error)" }
        guard let model = settings.liveModel else { return "Checking with macOS spelling and grammar" }
        return engine.isChecking ? "Checking with \(model.shortLabel)…" : "Checking as you type with \(model.shortLabel)"
    }

    @objc private func togglePaused() {
        settings.enabled.toggle()
    }

    @objc private func toggleApp() {
        guard let app = engine.lastTargetApp else { return }
        if let i = settings.excludedApps.firstIndex(of: app.bundleID) {
            settings.excludedApps.remove(at: i)
        } else {
            settings.excludedApps.append(app.bundleID)
        }
    }

    @objc private func openAccessibilitySettings() {
        AX.promptForTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettingsFromMenu() { openSettings() }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, client: client, speech: speech, reader: reader)))
            window.title = "Lex Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
