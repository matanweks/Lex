import AppKit
import Carbon.HIToolbox
import Combine
import QuillCore
import ServiceManagement
import Security
import SwiftUI

enum Keychain {
    static let service = "dev.quill.app"
    static let account = "anthropic-api-key"

    static func read() -> String? {
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

    static func write(_ value: String) {
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
        HotkeyPreset(id: "ctrl-opt-r", label: "⌃⌥R", keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey), menuKey: "r", menuModifiers: [.control, .option]),
        HotkeyPreset(id: "opt-shift-space", label: "⌥⇧Space", keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey), menuKey: " ", menuModifiers: [.option, .shift]),
        HotkeyPreset(id: "cmd-shift-semicolon", label: "⌘⇧;", keyCode: UInt32(kVK_ANSI_Semicolon), carbonModifiers: UInt32(cmdKey | shiftKey), menuKey: ";", menuModifiers: [.command, .shift]),
        HotkeyPreset(id: "ctrl-opt-space", label: "⌃⌥Space", keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), menuKey: " ", menuModifiers: [.control, .option]),
    ]

    static func find(_ id: String) -> HotkeyPreset { all.first { $0.id == id } ?? all[0] }
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

    init() {
        defaults.register(defaults: [
            "enabled": true,
            "liveModel": ClaudeModel.haiku.rawValue,
            "refineModel": ClaudeModel.sonnet.rawValue,
            "hotkey": HotkeyPreset.all[0].id,
            "showBadge": true,
            "excludedApps": Self.defaultExcluded,
        ])
        enabled = defaults.bool(forKey: "enabled")
        liveModelID = defaults.string(forKey: "liveModel") ?? ClaudeModel.haiku.rawValue
        refineModelID = defaults.string(forKey: "refineModel") ?? ClaudeModel.sonnet.rawValue
        hotkeyID = defaults.string(forKey: "hotkey") ?? HotkeyPreset.all[0].id
        showBadge = defaults.bool(forKey: "showBadge")
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? Self.defaultExcluded
        hasAPIKey = !(apiKey() ?? "").isEmpty
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

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let client: ClaudeClient
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
                Text("Text you type in checked apps is sent to the Anthropic API with this key. Quill never reads password fields.")
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
                Toggle("Show the issue badge next to the text field", isOn: $settings.showBadge)
                Toggle("Open Quill at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }

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
                Text("Apps Quill stays out of")
            } footer: {
                Text("Add an app from the menu bar icon while you're in it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .onReceive(trustPoll) { _ in
            if AX.isTrusted != trusted { trusted = AX.isTrusted }
        }
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
