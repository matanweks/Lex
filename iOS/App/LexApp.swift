import LexCore
import SwiftUI

@main
struct LexApp: App {
    @StateObject private var settings = LexSettings()
    @StateObject private var compose = ComposeModel()
    @StateObject private var clipboard = ClipboardModel()
    @StateObject private var articles = ArticleModel()
    @ObservedObject private var voice = VoiceSession.shared
    @State private var showListening = false
    @State private var tab = Tab.write
    @State private var welcome = !LocalStore.defaults.bool(forKey: "onboarded")
    /// When a link (the keyboard's mic, the share sheet, Shortcuts) last opened Lex.
    @State private var openedByLink = Date.distantPast
    @Environment(\.scenePhase) private var scenePhase

    enum Tab { case write, read, clipboard, settings }

    init() {
        // Settings saved before the keyboard could see them.
        SharedDefaults.moveIn(SharedDefaults.appKeys, from: LocalStore.defaults)
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
                SwiftUI.Tab("Read", systemImage: "newspaper", value: Tab.read) {
                    ArticleView(model: articles, reader: articles.reader)
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
                        Label("The keyboard's mic is on", systemImage: "mic.fill")
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
                    LocalStore.defaults.set(true, forKey: "onboarded")
                    welcome = false
                }
                .interactiveDismissDisabled()
            }
            .onOpenURL(perform: open)
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                settings.refreshKeys()
                // An article shared to Lex, in case the share sheet couldn't open Lex itself.
                if articles.takeFromShareSheet() { tab = .read }
                // A moment later, once it's known whether a link opened Lex (the keyboard's mic,
                // an article): then iOS's paste question would get in the way. Not while the
                // welcome sheet is up either, where it would land on top of it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !showListening, scenePhase == .active, Date().timeIntervalSince(openedByLink) > 3 else { return }
                    clipboard.captureIfChanged(enabled: settings.clipboardOnOpen && !welcome)
                }
            }
        }
    }

    /// `lex://write?text=…` opens the text in the Write tab and `lex://article?url=…` an article in
    /// the Read tab (both handy from Shortcuts); `lex://article` alone takes the share sheet's.
    private func open(_ url: URL) {
        openedByLink = Date()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "article":
            // From the share sheet, or lex://article?url=… (from Shortcuts).
            if let link = query.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)) {
                articles.open(link)
                tab = .read
            } else if articles.takeFromShareSheet() {
                tab = .read
            }
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
                LocalStore.defaults.set(true, forKey: "onboarded")
                welcome = false
            }
        #endif
        default:
            break
        }
    }
}
