import AppKit
import LexCore
import SwiftUI

/// The setup guide: what Lex needs (Accessibility, an API key), what's optional (dictation
/// permissions, Google voices), and the shortcuts. Opens on first launch and from the menu.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var google: GoogleSignIn
    let client: ClaudeClient
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    @State private var trusted = AX.isTrusted
    @State private var mic = Recorder.permission
    @State private var keyMonitoring = DictationController.keyMonitoringAllowed
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var testing = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var ready: Bool { trusted && settings.hasAPIKey }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    accessibilityStep
                    apiKeyStep
                    dictationStep
                    googleStep
                    shortcutsStep
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 680)
        .onReceive(poll) { _ in
            if AX.isTrusted != trusted { trusted = AX.isTrusted }
            if Recorder.permission != mic { mic = Recorder.permission }
            if DictationController.keyMonitoringAllowed != keyMonitoring { keyMonitoring = DictationController.keyMonitoringAllowed }
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Lex").font(.system(size: 24, weight: .bold))
                Text(Brand.tagline).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(LinearGradient(colors: [Brand.indigo.opacity(0.14), Brand.indigo.opacity(0.02)], startPoint: .top, endPoint: .bottom))
    }

    private var footer: some View {
        HStack {
            Button("Open Settings", action: onOpenSettings)
            Spacer()
            if !ready {
                Text("Lex needs steps 1 and 2 to check your writing.").font(.caption).foregroundStyle(.secondary)
            }
            Button(ready ? "Start Using Lex" : "Finish Later", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Steps

    private var accessibilityStep: some View {
        Step(number: 1, title: "Allow Accessibility", done: trusted, optional: false,
             detail: "Lex reads and fixes the text in whatever app you're typing in. Turn Lex on under Privacy & Security › Accessibility.") {
            if !trusted {
                Button("Open Accessibility Settings") {
                    AX.promptForTrust()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
    }

    private var apiKeyStep: some View {
        Step(number: 2, title: "Add your Anthropic API key", done: settings.hasAPIKey, optional: false,
             detail: "Claude checks each sentence as you finish it, and powers refine, translate, tone and summaries. The key stays in your Keychain.") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SecureField(settings.hasAPIKey ? "Saved. Paste a new key to replace it" : "sk-ant-…", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                }
                HStack {
                    if let keyStatus {
                        Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(.caption)
                }
            }
        }
    }

    private var dictationStep: some View {
        Step(number: 3, title: "Dictation", done: mic == .authorized && keyMonitoring, optional: true,
             detail: "Hold \(settings.dictationKey.short), talk, and let go to type. Lex needs the microphone, and Input Monitoring to see the key.") {
            VStack(alignment: .leading, spacing: 6) {
                permissionRow(mic == .authorized, "Microphone") {
                    if mic == .notDetermined {
                        Recorder.requestPermission { _ in mic = Recorder.permission }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
                permissionRow(keyMonitoring, "Input Monitoring") {
                    CGRequestListenEventAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
            }
        }
    }

    private var googleStep: some View {
        Step(number: 4, title: "Natural voices and Hebrew dictation", done: google.signedIn && !google.expired, optional: true,
             detail: googleDetail) {
            if google.expired {
                Button(google.signingIn ? "Waiting for the browser…" : "Sign In to Google Again") { google.signIn() }
                    .disabled(google.signingIn)
            } else if !google.signedIn {
                Button("Set Up in Settings", action: onOpenSettings)
            }
        }
    }

    private var googleDetail: String {
        if google.expired { return "Your Google sign-in expired. Until you sign in again, reading aloud uses the macOS voice." }
        if google.signedIn { return "Signed in with Google: reading aloud uses Google's natural voices." }
        return "Reading aloud works with the macOS voice. For Google's natural voices and Hebrew dictation, connect a Google Cloud project in Settings › Read aloud."
    }

    private var shortcutsStep: some View {
        Step(number: 5, title: "Your shortcuts", done: false, optional: false, detail: "Change any of them in Settings.", showsNumber: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                shortcut(settings.hotkey.label, "Refine what you just wrote")
                shortcut(settings.translateHotkey.label, "Translate between Hebrew and English")
                shortcut(settings.assistHotkey.label, "Summarize & reply to selected text")
                shortcut(settings.toneHotkey.label, "Check the tone of your message")
                shortcut(settings.fixAllHotkey.label, "Fix every mistake in the field")
                shortcut(settings.speakHotkey.label, "Read the selection aloud")
                shortcut(settings.clipboardHotkey.label, "Search what you copied and paste it again")
                shortcut("Hold \(settings.dictationKey.short)", "Dictate; over a selection, say how to change it")
            }
        }
    }

    // MARK: Pieces

    private func shortcut(_ keys: String, _ what: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            Text(what).font(.callout)
        }
    }

    private func permissionRow(_ ok: Bool, _ name: String, allow: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(name)
            Spacer()
            if !ok { Button("Allow", action: allow) }
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        settings.setAPIKey(key)
        keyDraft = ""
        guard settings.hasAPIKey else { keyStatus = "Couldn't save to the Keychain."; return }
        keyStatus = "Saved. Checking it works…"
        testing = true
        let model = settings.liveModel ?? .haiku
        Task {
            do {
                _ = try await client.check(sentence: "Their going to recieve it tomorow.", before: "", finished: true, model: model)
                await MainActor.run { keyStatus = "Works."; testing = false }
            } catch {
                await MainActor.run { keyStatus = error.localizedDescription; testing = false }
            }
        }
    }
}

/// One numbered card in the guide: a check once it's done, an "Optional" tag when it is.
private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let optional: Bool
    let detail: String
    var showsNumber = true
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsNumber {
                ZStack {
                    Circle().fill(done ? Color.green : Brand.indigo.opacity(0.14)).frame(width: 26, height: 26)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.indigo)
                    }
                }
            } else {
                Image(systemName: "keyboard").font(.system(size: 15)).foregroundStyle(Brand.indigo).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if optional {
                        Text("Optional").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}
