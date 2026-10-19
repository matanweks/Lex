import AppKit
import Combine
import LexCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = AppSettings()
    private lazy var client = ClaudeClient(apiKey: { [settings] in settings.apiKey() })
    private lazy var engine = Engine(settings: settings, client: client)
    private lazy var refine = RefineController(client: client, settings: settings, tracker: engine.tracker)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
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
        engine.onStatusChange = { [weak self] in self?.updateIcon() }

        settings.$hotkeyID.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotKey() }
        }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.engine.settingsChanged()
                self?.updateIcon()
            }
        }.store(in: &bag)

        Log.info("launch: trusted=\(AX.isTrusted) key=\(settings.hasAPIKey) model=\(settings.liveModelID) refine=\(settings.refineModelID)")
        if AX.isTrusted {
            engine.start()
        } else {
            AX.promptForTrust()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AX.isTrusted else { return }
                timer.invalidate()
                self?.engine.start()
                self?.updateIcon()
            }
        }
        if !settings.hasAPIKey { openSettings() }
        if settings.debugLog {
            debugHooks = DebugHooks(engine: engine, refine: refine, client: client) { [weak self] in self?.openRefine(scope: $0) }
            debugHooks?.install()
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, client: client)))
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
