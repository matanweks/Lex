import AppKit
import Carbon.HIToolbox
import Combine
import LexCore
import ServiceManagement
import Security
import SwiftUI

enum Keychain {
    static let service = "dev.lex.app"
    static let account = "anthropic-api-key"
    static let googleAccount = "google-tts-api-key"
    static let elevenLabsAccount = "elevenlabs-api-key"

    static func read(service: String = service, account: String = account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String = account) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        Log.info("keychain write status \(status)")
    }
}

struct HotkeyPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags

    static let all: [HotkeyPreset] = [
        HotkeyPreset(id: "opt-1", label: "⌥1", keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(optionKey), menuKey: "1", menuModifiers: [.option]),
        HotkeyPreset(id: "ctrl-opt-r", label: "⌃⌥R", keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey), menuKey: "r", menuModifiers: [.control, .option]),
        HotkeyPreset(id: "opt-shift-space", label: "⌥⇧Space", keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey), menuKey: " ", menuModifiers: [.option, .shift]),
        HotkeyPreset(id: "cmd-shift-semicolon", label: "⌘⇧;", keyCode: UInt32(kVK_ANSI_Semicolon), carbonModifiers: UInt32(cmdKey | shiftKey), menuKey: ";", menuModifiers: [.command, .shift]),
        HotkeyPreset(id: "ctrl-opt-space", label: "⌃⌥Space", keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), menuKey: " ", menuModifiers: [.control, .option]),
    ]

    static func find(_ id: String) -> HotkeyPreset { all.first { $0.id == id } ?? all[0] }

    /// For reading the selection aloud. ⌥⎋ is macOS's own "Speak selection" key, free when
    /// that feature is off in Accessibility › Spoken Content.
    static let speak: [HotkeyPreset] = [
        // § is the key left of 1 on ISO keyboards (kVK_ISO_Section, by position, any layout).
        HotkeyPreset(id: "opt-section", label: "⌥§", keyCode: UInt32(kVK_ISO_Section), carbonModifiers: UInt32(optionKey), menuKey: "§", menuModifiers: [.option]),
        HotkeyPreset(id: "ctrl-opt-s", label: "⌃⌥S", keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | optionKey), menuKey: "s", menuModifiers: [.control, .option]),
        HotkeyPreset(id: "opt-esc", label: "⌥⎋", keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(optionKey), menuKey: "\u{1b}", menuModifiers: [.option]),
        HotkeyPreset(id: "ctrl-opt-space-speak", label: "⌃⌥Space", keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), menuKey: " ", menuModifiers: [.control, .option]),
    ]

    static func findSpeak(_ id: String) -> HotkeyPreset { speak.first { $0.id == id } ?? speak[0] }

    /// For applying every fix in the field at once.
    static let fixAll: [HotkeyPreset] = [
        HotkeyPreset(id: "ctrl-section", label: "⌃§", keyCode: UInt32(kVK_ISO_Section), carbonModifiers: UInt32(controlKey), menuKey: "§", menuModifiers: [.control]),
        HotkeyPreset(id: "ctrl-opt-f", label: "⌃⌥F", keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(controlKey | optionKey), menuKey: "f", menuModifiers: [.control, .option]),
        HotkeyPreset(id: "opt-shift-f", label: "⌥⇧F", keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(optionKey | shiftKey), menuKey: "f", menuModifiers: [.option, .shift]),
        HotkeyPreset(id: "ctrl-opt-cmd-f", label: "⌃⌥⌘F", keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), menuKey: "f", menuModifiers: [.control, .option, .command]),
    ]

    static func findFixAll(_ id: String) -> HotkeyPreset { fixAll.first { $0.id == id } ?? fixAll[0] }
}

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private let keyLock = NSLock()
    private var cachedKey: String?

    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.1password.1password",
        "com.apple.keychainaccess",
    ]

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    /// A ClaudeModel raw value, or "off" for local-only checking.
    @Published var liveModelID: String { didSet { defaults.set(liveModelID, forKey: "liveModel") } }
    @Published var refineModelID: String { didSet { defaults.set(refineModelID, forKey: "refineModel") } }
    @Published var hotkeyID: String { didSet { defaults.set(hotkeyID, forKey: "hotkey") } }
    @Published var showBadge: Bool { didSet { defaults.set(showBadge, forKey: "showBadge") } }
    @Published var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published private(set) var hasAPIKey = false

    // Read aloud
    @Published var speechProviderID: String { didSet { defaults.set(speechProviderID, forKey: "speechProvider") } }
    @Published var googleVoice: String { didSet { defaults.set(googleVoice, forKey: "googleVoice") } }
    @Published var elevenVoiceID: String { didSet { defaults.set(elevenVoiceID, forKey: "elevenVoiceID") } }
    @Published var elevenModelID: String { didSet { defaults.set(elevenModelID, forKey: "elevenModel") } }
    @Published var speechSpeed: Double { didSet { defaults.set(speechSpeed, forKey: "speechSpeed") } }
    @Published var speakHotkeyID: String { didSet { defaults.set(speakHotkeyID, forKey: "speakHotkey") } }
    @Published var fixAllHotkeyID: String { didSet { defaults.set(fixAllHotkeyID, forKey: "fixAllHotkey") } }
    @Published private(set) var hasGoogleKey = false

    // Dictation
    @Published var dictationKeyID: String { didSet { defaults.set(dictationKeyID, forKey: "dictationKey") } }
    @Published var dictationEngineID: String { didSet { defaults.set(dictationEngineID, forKey: "dictationEngine") } }
    @Published var dictationLanguagesID: String { didSet { defaults.set(dictationLanguagesID, forKey: "dictationLanguages") } }
    @Published var dictationPolish: Bool { didSet { defaults.set(dictationPolish, forKey: "dictationPolish") } }
    @Published var dictationWords: String { didSet { defaults.set(dictationWords, forKey: "dictationWords") } }
    @Published private(set) var hasElevenKey = false
    private var cachedSpeechKeys: [String: String] = [:]

    init() {
        Self.migrateFromQuill(into: defaults)
        defaults.register(defaults: [
            "enabled": true,
            "liveModel": ClaudeModel.haiku.rawValue,
            "refineModel": ClaudeModel.sonnet.rawValue,
            "hotkey": HotkeyPreset.all[0].id,
            "showBadge": true,
            "excludedApps": Self.defaultExcluded,
            "speechProvider": SpeechProvider.google.rawValue,
            "googleVoice": "Kore",
            "elevenVoiceID": ElevenLabsTTS.defaultVoiceID,
            "elevenModel": ElevenLabsTTS.Model.flash.rawValue,
            "speechSpeed": 1.0,
            "speakHotkey": HotkeyPreset.speak[0].id,
            "fixAllHotkey": HotkeyPreset.fixAll[0].id,
            "dictationKey": DictationKey.rightOption.rawValue,
            "dictationEngine": DictationEngine.auto.rawValue,
            "dictationLanguages": DictationLanguages.englishHebrew.rawValue,
            "dictationPolish": true,
            "dictationWords": "",
        ])
        enabled = defaults.bool(forKey: "enabled")
        liveModelID = defaults.string(forKey: "liveModel") ?? ClaudeModel.haiku.rawValue
        refineModelID = defaults.string(forKey: "refineModel") ?? ClaudeModel.sonnet.rawValue
        hotkeyID = defaults.string(forKey: "hotkey") ?? HotkeyPreset.all[0].id
        showBadge = defaults.bool(forKey: "showBadge")
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? Self.defaultExcluded
        speechProviderID = defaults.string(forKey: "speechProvider") ?? SpeechProvider.google.rawValue
        googleVoice = defaults.string(forKey: "googleVoice") ?? "Kore"
        elevenVoiceID = defaults.string(forKey: "elevenVoiceID") ?? ElevenLabsTTS.defaultVoiceID
        elevenModelID = defaults.string(forKey: "elevenModel") ?? ElevenLabsTTS.Model.flash.rawValue
        speechSpeed = defaults.double(forKey: "speechSpeed")
        speakHotkeyID = defaults.string(forKey: "speakHotkey") ?? HotkeyPreset.speak[0].id
        fixAllHotkeyID = defaults.string(forKey: "fixAllHotkey") ?? HotkeyPreset.fixAll[0].id
        dictationKeyID = defaults.string(forKey: "dictationKey") ?? DictationKey.rightOption.rawValue
        dictationEngineID = defaults.string(forKey: "dictationEngine") ?? DictationEngine.auto.rawValue
        dictationLanguagesID = defaults.string(forKey: "dictationLanguages") ?? DictationLanguages.englishHebrew.rawValue
        dictationPolish = defaults.bool(forKey: "dictationPolish")
        dictationWords = defaults.string(forKey: "dictationWords") ?? ""
        hasAPIKey = !(apiKey() ?? "").isEmpty
        hasGoogleKey = !(speechKey(for: .google) ?? "").isEmpty
        hasElevenKey = !(speechKey(for: .elevenLabs) ?? "").isEmpty
    }

    var speechProvider: SpeechProvider { SpeechProvider(rawValue: speechProviderID) ?? .google }
    var dictationKey: DictationKey { DictationKey(rawValue: dictationKeyID) ?? .rightOption }
    var dictationEngine: DictationEngine { DictationEngine(rawValue: dictationEngineID) ?? .auto }
    var dictationLanguages: DictationLanguages { DictationLanguages(rawValue: dictationLanguagesID) ?? .englishHebrew }
    var dictationWordList: [String] {
        dictationWords.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Seconds of audio sent to Google this month.
    var dictationSeconds: Double { defaults.double(forKey: Self.monthKey("dictationSeconds")) }

    func addDictationSeconds(_ s: Double) {
        let key = Self.monthKey("dictationSeconds")
        defaults.set(defaults.double(forKey: key) + s, forKey: key)
        objectWillChange.send()
    }

    private static func monthKey(_ base: String) -> String {
        let month = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(base)-\(month.year ?? 0)-\(month.month ?? 0)"
    }
    var elevenModel: ElevenLabsTTS.Model { ElevenLabsTTS.Model(rawValue: elevenModelID) ?? .flash }
    var speakHotkey: HotkeyPreset { HotkeyPreset.findSpeak(speakHotkeyID) }
    var fixAllHotkey: HotkeyPreset { HotkeyPreset.findFixAll(fixAllHotkeyID) }

    private static func account(for provider: SpeechProvider) -> String? {
        switch provider {
        case .google: return Keychain.googleAccount
        case .elevenLabs: return Keychain.elevenLabsAccount
        case .system: return nil
        }
    }

    /// Google or ElevenLabs key from the Keychain (read once). Safe from any thread.
    func speechKey(for provider: SpeechProvider) -> String? {
        guard let account = Self.account(for: provider) else { return nil }
        keyLock.lock(); defer { keyLock.unlock() }
        if cachedSpeechKeys[account] == nil { cachedSpeechKeys[account] = Keychain.read(account: account) ?? "" }
        let key = cachedSpeechKeys[account]!
        return key.isEmpty ? nil : key
    }

    func setSpeechKey(_ key: String, for provider: SpeechProvider) {
        guard let account = Self.account(for: provider) else { return }
        Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
        let stored = Keychain.read(account: account) ?? ""
        keyLock.lock(); cachedSpeechKeys[account] = stored; keyLock.unlock()
        if provider == .google { hasGoogleKey = !stored.isEmpty } else { hasElevenKey = !stored.isEmpty }
    }

    /// Characters sent to a speech service this calendar month (cached audio not counted).
    func speechUsage(for provider: SpeechProvider) -> Int {
        defaults.integer(forKey: Self.usageKey(provider))
    }

    func addSpeechUsage(_ characters: Int, for provider: SpeechProvider) {
        let key = Self.usageKey(provider)
        defaults.set(defaults.integer(forKey: key) + characters, forKey: key)
        objectWillChange.send()
    }

    private static func usageKey(_ provider: SpeechProvider) -> String {
        let month = Calendar.current.dateComponents([.year, .month], from: Date())
        return "speechUsage-\(provider.rawValue)-\(month.year ?? 0)-\(month.month ?? 0)"
    }

    /// Lex used to be called Quill (bundle dev.quill.app). Once, copy its settings and API key
    /// so the rename costs nothing but the Accessibility grant, which macOS ties to the app.
    /// Reading the old Keychain item may show a one-time "Lex wants to use…" prompt.
    private static func migrateFromQuill(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: "migratedFromQuill") else { return }
        defaults.set(true, forKey: "migratedFromQuill")
        var copied: [String] = []
        if let old = UserDefaults(suiteName: "dev.quill.app") {
            for key in ["enabled", "liveModel", "refineModel", "hotkey", "showBadge", "excludedApps", "debugLog"] {
                if let value = old.object(forKey: key), defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                    copied.append(key)
                }
            }
        }
        var key = false
        if Keychain.read() == nil, let oldKey = Keychain.read(service: "dev.quill.app"), !oldKey.isEmpty {
            Keychain.write(oldKey)
            key = true
        }
        Log.info("migrated from Quill: settings \(copied), api key \(key)")
    }

    var liveModel: ClaudeModel? { ClaudeModel(rawValue: liveModelID) }
    var refineModel: ClaudeModel { ClaudeModel(rawValue: refineModelID) ?? .sonnet }
    var hotkey: HotkeyPreset { HotkeyPreset.find(hotkeyID) }
    var debugLog: Bool { defaults.bool(forKey: "debugLog") }

    /// Safe to call from any thread; reads the Keychain once.
    func apiKey() -> String? {
        keyLock.lock(); defer { keyLock.unlock() }
        if cachedKey == nil { cachedKey = Keychain.read() ?? "" }
        return cachedKey!.isEmpty ? nil : cachedKey
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(trimmed)
        // Read it back so "saved" means saved.
        let stored = Keychain.read() ?? ""
        keyLock.lock(); cachedKey = stored; keyLock.unlock()
        hasAPIKey = !stored.isEmpty
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.info("launch at login: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let client: ClaudeClient
    let speech: SpeechClient
    let reader: Reader
    @State private var googleKeyDraft = ""
    @State private var elevenKeyDraft = ""
    @State private var elevenVoices: [VoiceOption] = []
    @State private var googleSignedIn = false
    @State private var googleProject: String?
    @State private var checkingVoice = false
    @State private var voiceCheck: String?
    @State private var keyDraft = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var trusted = AX.isTrusted
    private let trustPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Status") {
                HStack {
                    statusIcon(trusted)
                    Text(trusted ? "Accessibility is allowed" : "Accessibility isn't allowed yet")
                    Spacer()
                    if !trusted {
                        Button("Open System Settings") {
                            AX.promptForTrust()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                HStack {
                    statusIcon(settings.hasAPIKey)
                    Text(settings.hasAPIKey ? "API key saved in your Keychain" : "No API key yet: paste it below and press Return")
                }
            }

            Section {
                HStack {
                    SecureField(settings.hasAPIKey ? "Paste a new key to replace the saved one" : "sk-ant-…", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .keyboardShortcut(.defaultAction)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { runTest() }
                        .disabled(!settings.hasAPIKey || testing)
                    if let testResult {
                        Text(testResult).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.callout)
                }
            } header: {
                Text("Anthropic API key")
            } footer: {
                Text("Text you type in checked apps is sent to the Anthropic API with this key. Lex never reads password fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Models") {
                Picker("Check while typing", selection: $settings.liveModelID) {
                    Text("Off (macOS spelling and grammar only)").tag("off")
                    ForEach(ClaudeModel.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Refine", selection: $settings.refineModelID) {
                    ForEach(ClaudeModel.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            Section("Behavior") {
                Picker("Refine shortcut", selection: $settings.hotkeyID) {
                    ForEach(HotkeyPreset.all) { Text($0.label).tag($0.id) }
                }
                Picker("Fix all mistakes", selection: $settings.fixAllHotkeyID) {
                    ForEach(HotkeyPreset.fixAll) { Text($0.label).tag($0.id) }
                }
                Toggle("Show the issue badge next to the text field", isOn: $settings.showBadge)
                Toggle("Open Lex at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }

            readAloudSection

            dictationSection

            Section {
                if settings.excludedApps.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(settings.excludedApps, id: \.self) { id in
                    HStack {
                        Text(Self.appName(id)).lineLimit(1)
                        Text(id).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Button {
                            settings.excludedApps.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Apps Lex stays out of")
            } footer: {
                Text("Add an app from the menu bar icon while you're in it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 780)
        .onReceive(trustPoll) { _ in
            if AX.isTrusted != trusted { trusted = AX.isTrusted }
            let creds = speech.adc.credentials()
            if (creds != nil) != googleSignedIn { googleSignedIn = creds != nil }
            if creds?.quotaProject != googleProject { googleProject = creds?.quotaProject }
        }
    }

    // MARK: Dictation

    @State private var micStatus = Recorder.permission
    @State private var keyMonitoring = DictationController.keyMonitoringAllowed

    @ViewBuilder private var dictationSection: some View {
        Section {
            HStack {
                statusIcon(micStatus == .authorized)
                Text(micStatus == .authorized ? "Microphone allowed" : micStatus == .notDetermined ? "Lex will ask for the microphone the first time" : "Microphone not allowed")
                Spacer()
                if micStatus == .notDetermined {
                    Button("Allow now") { Recorder.requestPermission { _ in micStatus = Recorder.permission } }
                } else if micStatus != .authorized {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
            HStack {
                statusIcon(keyMonitoring)
                Text(keyMonitoring ? "Input Monitoring allowed (for the talk key)" : "Input Monitoring not allowed: Lex can't see the talk key")
                Spacer()
                if !keyMonitoring {
                    Button("Open System Settings") {
                        CGRequestListenEventAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                }
            }
            Picker("Talk key", selection: $settings.dictationKeyID) {
                ForEach(DictationKey.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Engine", selection: $settings.dictationEngineID) {
                ForEach(DictationEngine.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if settings.dictationEngine != .apple {
                Picker(settings.dictationEngine == .auto ? "Languages with Google" : "Languages", selection: $settings.dictationLanguagesID) {
                    ForEach(DictationLanguages.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if !googleSignedIn {
                    Text("Needs the gcloud sign-in from Read aloud above, with Speech-to-Text enabled: gcloud services enable speech.googleapis.com --project PROJECT_ID")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Toggle("Tidy up with Claude: drop \"um\"s, apply \"no wait…\" corrections, fix punctuation", isOn: $settings.dictationPolish)
            VStack(alignment: .leading, spacing: 4) {
                Text("Words to know")
                TextField("Names and terms, comma separated: Pelles, Procore, Trimble", text: $settings.dictationWords)
                    .textFieldStyle(.roundedBorder)
            }
            Text(dictationUsage).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Dictation")
        } footer: {
            Text("Hold \(settings.dictationKey.short) and talk; let go to type it where your cursor is. Double-tap it for hands-free and tap once more to finish; esc cancels. Using the key with another key (typing a special character) never dictates.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(trustPoll) { _ in
            if Recorder.permission != micStatus { micStatus = Recorder.permission }
            if DictationController.keyMonitoringAllowed != keyMonitoring { keyMonitoring = DictationController.keyMonitoringAllowed }
        }
    }

    private var dictationUsage: String {
        guard settings.dictationEngine != .apple else { return "Free: transcribed on this Mac" }
        let minutes = settings.dictationSeconds / 60
        return String(format: "This month: %.1f minutes dictated, about $%.2f", minutes, minutes * 0.016)
    }

    // MARK: Read aloud

    @ViewBuilder private var readAloudSection: some View {
        Section {
            Picker("Voice service", selection: $settings.speechProviderID) {
                ForEach(SpeechProvider.allCases) { Text($0.label).tag($0.rawValue) }
            }
            switch settings.speechProvider {
            case .google:
                HStack {
                    statusIcon(googleSignedIn || settings.hasGoogleKey)
                    Text(googleStatus)
                    Spacer()
                    Button(checkingVoice ? "Checking…" : "Check connection") { checkGoogle() }
                        .disabled(checkingVoice || !(googleSignedIn || settings.hasGoogleKey))
                }
                if let voiceCheck {
                    Text(voiceCheck).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !googleSignedIn && !settings.hasGoogleKey {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sign in once with gcloud (works where your organisation blocks API keys). In Terminal, with your project ID:")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Self.gcloudSteps)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
                DisclosureGroup("Use an API key instead") {
                    keyRow(saved: settings.hasGoogleKey, placeholder: "Google Cloud API key", draft: $googleKeyDraft) {
                        settings.setSpeechKey($0, for: .google)
                    }
                }
                Picker("Voice", selection: $settings.googleVoice) {
                    ForEach(GoogleTTS.voices, id: \.name) { Text("\($0.name), \($0.description.lowercased())").tag($0.name) }
                }
            case .elevenLabs:
                keyRow(saved: settings.hasElevenKey, placeholder: "ElevenLabs API key", draft: $elevenKeyDraft) {
                    settings.setSpeechKey($0, for: .elevenLabs)
                }
                Picker("Model", selection: $settings.elevenModelID) {
                    ForEach(ElevenLabsTTS.Model.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Voice", selection: $settings.elevenVoiceID) {
                    if !elevenVoices.contains(where: { $0.id == settings.elevenVoiceID }) {
                        Text(settings.elevenVoiceID == ElevenLabsTTS.defaultVoiceID ? "George (default)" : "Current voice").tag(settings.elevenVoiceID)
                    }
                    ForEach(elevenVoices) { Text($0.name).tag($0.id) }
                }
                .task(id: settings.hasElevenKey) { await loadElevenVoices() }
                Link("Get a key", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!).font(.caption)
            case .system:
                Text("Uses the best macOS voice installed for the text's language. Premium voices sound much better: add them in System Settings › Accessibility › Spoken Content › System voice › Manage Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Speed")
                Slider(value: $settings.speechSpeed, in: 0.8...2.0, step: 0.05)
                Text(ReaderHUDView.speedLabel((settings.speechSpeed * 20).rounded() / 20)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Picker("Read-aloud shortcut", selection: $settings.speakHotkeyID) {
                ForEach(HotkeyPreset.speak) { Text($0.label).tag($0.id) }
            }
            HStack {
                Button("Play a sample") {
                    reader.read("Hi! This is how Lex reads your text aloud. Select any text, press \(settings.speakHotkey.label), and listen.")
                }
                Spacer()
                Text(usageLine).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Read aloud")
        } footer: {
            Text("Select text anywhere and press \(settings.speakHotkey.label); press it again to stop. The text goes to the voice service you pick. Audio is cached on this Mac, so hearing the same text again is free.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static let gcloudSteps = """
    brew install --cask gcloud-cli
    gcloud auth application-default login
    gcloud auth application-default set-quota-project PROJECT_ID
    gcloud services enable texttospeech.googleapis.com --project PROJECT_ID
    """

    private var googleStatus: String {
        if settings.hasGoogleKey { return "Using your Google API key" }
        guard googleSignedIn else { return "Not connected to Google yet" }
        return googleProject.map { "Signed in with gcloud, billing project \($0)" } ?? "Signed in with gcloud, but no quota project set"
    }

    /// Synthesizes a few words (not played) to prove the sign-in, project and API all work.
    private func checkGoogle() {
        checkingVoice = true
        voiceCheck = nil
        let request = SpeechClient.Request(
            text: "Lex voice check \(Int(Date().timeIntervalSince1970)).", provider: .google, key: settings.speechKey(for: .google) ?? "",
            googleLocale: "en-US", googleVoice: settings.googleVoice, elevenVoiceID: "", elevenModel: .flash)
        let started = Date()
        Task {
            do {
                let (audio, _) = try await speech.synthesize(request)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run { voiceCheck = "Works: \(audio.count / 1024) KB of audio in \(ms) ms."; checkingVoice = false }
            } catch {
                await MainActor.run { voiceCheck = error.localizedDescription; checkingVoice = false }
            }
        }
    }

    private func keyRow(saved: Bool, placeholder: String, draft: Binding<String>, save: @escaping (String) -> Void) -> some View {
        HStack {
            statusIcon(saved)
            SecureField(saved ? "Saved in your Keychain. Paste a new key to replace it" : placeholder, text: draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(draft, save) }
            Button("Save") { commit(draft, save) }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func commit(_ draft: Binding<String>, _ save: (String) -> Void) {
        let key = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        save(key)
        draft.wrappedValue = ""
    }

    private var usageLine: String {
        let provider = settings.speechProvider
        guard provider != .system else { return "Free" }
        let used = settings.speechUsage(for: provider)
        let formatted = used.formatted()
        if provider == .google {
            let free = provider.freeCharactersPerMonth
            return used <= free ? "This month: \(formatted) of \(free.formatted()) free characters"
                : "This month: \(formatted) characters, about $\(String(format: "%.2f", Double(used - free) / 1000 * provider.pricePer1k(model: settings.elevenModel)))"
        }
        return "This month: \(formatted) characters, about $\(String(format: "%.2f", Double(used) / 1000 * provider.pricePer1k(model: settings.elevenModel)))"
    }

    private func loadElevenVoices() async {
        guard let key = settings.speechKey(for: .elevenLabs) else { return }
        let voices = await speech.elevenLabsVoices(key: key)
        await MainActor.run { elevenVoices = voices.map { VoiceOption(id: $0.id, name: $0.name) } }
    }

    private func statusIcon(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        settings.setAPIKey(key)
        keyDraft = ""
        testResult = settings.hasAPIKey ? "Saved." : "Couldn't save to the Keychain."
        if settings.hasAPIKey { runTest() }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func runTest() {
        testing = true
        testResult = nil
        let model = settings.liveModel ?? .haiku
        let started = Date()
        Task {
            do {
                let edits = try await client.check(sentence: "Their going to recieve the package tomorow.", before: "", finished: true, model: model)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run {
                    testResult = "Works: \(model.shortLabel) found \(edits.count) fixes in \(ms) ms"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = error.localizedDescription
                    testing = false
                }
            }
        }
    }
}
