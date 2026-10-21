import LexCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: LexSettings
    let onClearClipboard: () -> Void
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var testing = false
    @State private var speechKeyDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                header
                claudeSection
                writingSection
                readAloudSection
                dictationSection
                clipboardSection
                Section("Use Lex everywhere") {
                    tip("square.and.arrow.up", "In any app, select text, tap Share, then Lex. If Lex isn't in the row, tap More and add it.")
                    tip("bolt.fill", "In Shortcuts, Lex can fix, translate or summarize your clipboard. Put Fix My Clipboard on the Action button in Settings › Action Button › Shortcut.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Image("LexMark")
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lex \(Brand.version)").font(.headline)
                    Text(Brand.tagline).font(.footnote).foregroundStyle(.secondary)
                    Link("github.com/matanweks/Lex", destination: Brand.repo).font(.footnote)
                }
            }
        }
    }

    private var claudeSection: some View {
        Section {
            SecureField(settings.hasAPIKey ? "Saved. Paste a new key to replace it" : "Anthropic API key (sk-ant-…)", text: $keyDraft)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(saveKey)
            HStack {
                Button("Save Key", action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                Spacer()
                if settings.hasAPIKey {
                    Button("Remove", role: .destructive) { settings.setAPIKey(""); keyStatus = nil }
                }
            }
            if let keyStatus { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
            Picker("Rewrites", selection: $settings.rewriteModelID) {
                ForEach(ClaudeModel.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Fixes and dictation", selection: $settings.quickModelID) {
                ForEach(ClaudeModel.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("The key stays in this iPhone's Keychain and is sent only to Anthropic. [Get a key](https://console.anthropic.com/settings/keys)")
        }
    }

    private var writingSection: some View {
        Section {
            Picker("Writing for", selection: $settings.contextID) {
                ForEach(WritingContext.allCases) { Text($0.shortLabel).tag($0.rawValue) }
            }
            TextField("How it should read", text: Binding(get: { settings.style(for: settings.context) },
                                                          set: { settings.setStyle($0, for: settings.context) }), axis: .vertical)
                .lineLimit(2...5)
            TextField("Your voice (optional): how you write, in a sentence or two", text: $settings.voiceProfile, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Your style")
        } footer: {
            Text("Rewrites and dictation follow the style for what you're writing. Switch it from the Write tab too.")
        }
    }

    private var readAloudSection: some View {
        Section {
            Picker("Voice", selection: $settings.speechProviderID) {
                Text("iPhone voice (free, offline)").tag(SpeechProvider.system.rawValue)
                Text("Google Chirp 3 HD").tag(SpeechProvider.google.rawValue)
                Text("ElevenLabs").tag(SpeechProvider.elevenLabs.rawValue)
            }
            .onChange(of: settings.speechProviderID) { settings.refreshKeys() }
            if settings.speechProvider == .google {
                Picker("Google voice", selection: $settings.googleVoice) {
                    ForEach(GoogleTTS.voices, id: \.name) { Text("\($0.name) · \($0.description)").tag($0.name) }
                }
            }
            if settings.speechProvider != .system {
                SecureField(settings.hasSpeechKey ? "Key saved. Paste a new one to replace it" : "\(settings.speechProvider == .google ? "Google Cloud" : "ElevenLabs") API key", text: $speechKeyDraft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { settings.setSpeechKey(speechKeyDraft, for: settings.speechProvider); speechKeyDraft = "" }
            }
            HStack {
                Text("Speed")
                Slider(value: $settings.speechSpeed, in: 0.8...2.0, step: 0.25)
                Text("\(settings.speechSpeed, specifier: "%.2g")×").monospacedDigit().foregroundStyle(.secondary)
            }
        } header: {
            Text("Read aloud")
        } footer: {
            Text(settings.speechProvider == .google
                 ? "Google needs an API key limited to the Text-to-Speech API. The Mac's gcloud sign-in doesn't exist on iPhone."
                 : "For a better iPhone voice, download an Enhanced or Premium one in Settings › Accessibility › Spoken Content › Voices.")
        }
    }

    private var dictationSection: some View {
        Section {
            Picker("Language", selection: $settings.dictationLanguage) {
                Text("English").tag("en")
                Text("Hebrew").tag("he")
            }
            Toggle("Tidy up with Claude", isOn: $settings.dictationPolish)
            Toggle("Hebrew speech comes out in English", isOn: $settings.dictationTranslateHebrew)
            TextField("Names and terms, comma-separated", text: $settings.dictationWords, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Dictation")
        } footer: {
            Text("Apple's on-device speech hears you, free and private. Claude then removes fillers and false starts and fixes punctuation, keeping your words.")
        }
    }

    private var clipboardSection: some View {
        Section {
            Toggle("Save the clipboard when Lex opens", isOn: $settings.clipboardOnOpen)
            Picker("Keep for", selection: $settings.clipboardDays) {
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            Button("Clear History", role: .destructive, action: onClearClipboard)
        } header: {
            Text("Clipboard")
        } footer: {
            Text("Saved only on this iPhone. Pinned entries are kept until you unpin them.")
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Brand.indigo)
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
        let model = ClaudeModel(rawValue: settings.quickModelID) ?? .haiku
        Task {
            do {
                _ = try await LexEngine.claude.check(sentence: "Their going to recieve it tomorow.", before: "", finished: true, model: model)
                keyStatus = "Works."
            } catch {
                keyStatus = error.localizedDescription
            }
            testing = false
        }
    }
}

/// The first-run guide: the key Lex needs, and where Lex shows up outside the app.
struct WelcomeView: View {
    @ObservedObject var settings: LexSettings
    let onDone: () -> Void
    @State private var keyDraft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to Lex").font(.largeTitle.bold())
                        Text(Brand.tagline).foregroundStyle(.secondary)
                    }
                    step(1, "Add your Anthropic API key", done: settings.hasAPIKey) {
                        Text("Claude does the writing work. The key stays in your Keychain.").foregroundStyle(.secondary)
                        HStack {
                            SecureField("sk-ant-…", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Save") { settings.setAPIKey(keyDraft); keyDraft = "" }
                                .buttonStyle(.borderedProminent)
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(.footnote)
                    }
                    step(2, "Use Lex in any app", done: false) {
                        Text("Select text, tap Share, then Lex: fix it, rewrite it, translate it or summarize it, and copy the result back.").foregroundStyle(.secondary)
                    }
                    step(3, "Or from Shortcuts", done: false) {
                        Text("Fix My Clipboard, Translate My Clipboard and Run a Lex Action are in the Shortcuts app. Put one on the Action button or Back Tap.").foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button(settings.hasAPIKey ? "Start Writing" : "Finish Later", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.bar)
            }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Brand.indigo.opacity(0.15)).frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.subheadline.bold()).foregroundStyle(Brand.indigo)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
