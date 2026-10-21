import LexCore
import SwiftUI

@main
struct LexApp: App {
    @StateObject private var settings = LexSettings()
    @StateObject private var compose = ComposeModel()
    @StateObject private var clipboard = ClipboardModel()
    @ObservedObject private var voice = VoiceSession.shared
    @State private var showListening = false
    @State private var tab = Tab.write
    @State private var welcome = !AppGroup.defaults.bool(forKey: "onboarded")
    @Environment(\.scenePhase) private var scenePhase

    enum Tab { case write, clipboard, settings }

    init() {
        #if DEBUG
        StubClaude.configure()
        #endif
        VoiceSession.shared.clearLeftovers()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                SwiftUI.Tab("Write", systemImage: "square.and.pencil", value: Tab.write) {
                    ComposeView(compose: compose, settings: settings)
                }
                SwiftUI.Tab("Clipboard", systemImage: "list.clipboard", value: Tab.clipboard) {
                    ClipboardView(model: clipboard, settings: settings) { text in
                        compose.text = text
                        compose.selection = nil
                        tab = .write
                    }
                }
                SwiftUI.Tab("Settings", systemImage: "gearshape", value: Tab.settings) {
                    SettingsView(settings: settings, onClearClipboard: clipboard.clear)
                }
            }
            .tint(Brand.indigo)
            .safeAreaInset(edge: .top) {
                if voice.isOn && !showListening {
                    Button { showListening = true } label: {
                        Label("The keyboard's mic is ready", systemImage: "mic.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Brand.orange.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .fullScreenCover(isPresented: $showListening) {
                ListeningView(session: voice) { showListening = false }
            }
            .sheet(isPresented: $welcome) {
                WelcomeView(settings: settings) {
                    AppGroup.defaults.set(true, forKey: "onboarded")
                    welcome = false
                }
                .interactiveDismissDisabled()
            }
            .onOpenURL(perform: open)
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                settings.refreshKeys()
                // Not while the welcome sheet is up: iOS's paste question would land on top of it.
                clipboard.captureIfChanged(enabled: settings.clipboardOnOpen && !welcome)
            }
        }
    }

    /// `lex://write?text=…` opens the text in the Write tab (handy from Shortcuts).
    private func open(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "listen":
            // The Lex keyboard wants to dictate: start the mic while Lex is in front.
            showListening = true
            Task { await voice.begin() }
        case "write":
            if let text = query.first(where: { $0.name == "text" })?.value {
                compose.text = text
                compose.selection = nil
            }
            tab = .write
        #if DEBUG
        case "debug":
            // Test support: lex://debug?dictate=/path/to/audio.wav dictates a file into the editor.
            if let path = query.first(where: { $0.name == "dictate" })?.value {
                tab = .write
                compose.dictationFile = URL(fileURLWithPath: path)
            }
            if query.contains(where: { $0.name == "skip-welcome" }) {
                AppGroup.defaults.set(true, forKey: "onboarded")
                welcome = false
            }
        #endif
        default:
            break
        }
    }
}
