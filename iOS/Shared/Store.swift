import Foundation
import LexCore
import Security
import SwiftUI

/// What the app, the share sheet and Shortcuts share: settings and the clipboard history live
/// in the app group, keys in a Keychain group all three can read.
enum AppGroup {
    static let id = "group.dev.lex.ios"

    static let defaults = UserDefaults(suiteName: id) ?? .standard

    /// The shared folder. An unsigned build has no group, so it falls back to the app's own.
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

/// API keys, in the Keychain group named first in the entitlements (so every Lex target sees
/// them). Readable after the first unlock, so Shortcuts work while the phone is locked.
enum Keychain {
    static let service = "dev.lex.app"
    static let anthropic = "anthropic-api-key"
    static let google = "google-tts-api-key"
    static let elevenLabs = "elevenlabs-api-key"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value`, or removes the key when it's empty.
    static func write(_ value: String, _ account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !value.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// The settings as plain values, read fresh from the app group. Safe on any thread, so
/// Shortcuts and the share sheet use this rather than `LexSettings`.
struct Prefs {
    var rewriteModel: ClaudeModel
    var quickModel: ClaudeModel
    var context: WritingContext
    var style: String
    var voice: String
    var dictationPolish: Bool
    var dictationTranslateHebrew: Bool
    var dictationWords: [String]
    var snippets: [Snippet]

    static var current: Prefs {
        let d = AppGroup.defaults
        let context = WritingContext(rawValue: d.string(forKey: "context") ?? "") ?? .chat
        let styles = d.dictionary(forKey: "styles") as? [String: String] ?? [:]
        let voice = d.string(forKey: "voiceProfile") ?? ""
        return Prefs(
            rewriteModel: ClaudeModel(rawValue: d.string(forKey: "refineModel") ?? "") ?? .sonnet,
            quickModel: ClaudeModel(rawValue: d.string(forKey: "liveModel") ?? "") ?? .haiku,
            context: context,
            style: styles[context.rawValue] ?? WritingContext.defaultStyle[context] ?? "",
            voice: voice.trimmingCharacters(in: .whitespacesAndNewlines),
            dictationPolish: d.object(forKey: "dictationPolish") as? Bool ?? true,
            dictationTranslateHebrew: d.bool(forKey: "dictationTranslateHebrew"),
            dictationWords: (d.string(forKey: "dictationWords") ?? "")
                .split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            snippets: Self.snippets(d))
    }

    /// Saved the same way as on the Mac (JSON under "snippets").
    static func snippets(_ d: UserDefaults) -> [Snippet] {
        d.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }
}

/// The settings screen's view of the same values. Every change is written straight to the
/// app group, where `Prefs` and the other Lex targets read it.
final class LexSettings: ObservableObject {
    private let d = AppGroup.defaults

    @Published var rewriteModelID: String { didSet { d.set(rewriteModelID, forKey: "refineModel") } }
    @Published var quickModelID: String { didSet { d.set(quickModelID, forKey: "liveModel") } }
    @Published var contextID: String { didSet { d.set(contextID, forKey: "context") } }
    @Published var styles: [String: String] { didSet { d.set(styles, forKey: "styles") } }
    @Published var voiceProfile: String { didSet { d.set(voiceProfile, forKey: "voiceProfile") } }
    @Published var speechProviderID: String { didSet { d.set(speechProviderID, forKey: "speechProvider") } }
    @Published var googleVoice: String { didSet { d.set(googleVoice, forKey: "googleVoice") } }
    @Published var speechSpeed: Double { didSet { d.set(speechSpeed, forKey: "speechSpeed") } }
    @Published var dictationLanguage: String { didSet { d.set(dictationLanguage, forKey: "dictationLanguage") } }
    @Published var dictationPolish: Bool { didSet { d.set(dictationPolish, forKey: "dictationPolish") } }
    @Published var dictationTranslateHebrew: Bool { didSet { d.set(dictationTranslateHebrew, forKey: "dictationTranslateHebrew") } }
    @Published var dictationWords: String { didSet { d.set(dictationWords, forKey: "dictationWords") } }
    @Published var clipboardOnOpen: Bool { didSet { d.set(clipboardOnOpen, forKey: "clipboardOnOpen") } }
    @Published var clipboardDays: Int { didSet { d.set(clipboardDays, forKey: "clipboardDays") } }
    @Published var snippets: [Snippet] { didSet { d.set(try? JSONEncoder().encode(snippets), forKey: "snippets") } }
    @Published private(set) var hasAPIKey = false
    @Published private(set) var hasSpeechKey = false

    init() {
        rewriteModelID = d.string(forKey: "refineModel") ?? ClaudeModel.sonnet.rawValue
        quickModelID = d.string(forKey: "liveModel") ?? ClaudeModel.haiku.rawValue
        contextID = d.string(forKey: "context") ?? WritingContext.chat.rawValue
        styles = d.dictionary(forKey: "styles") as? [String: String] ?? [:]
        voiceProfile = d.string(forKey: "voiceProfile") ?? ""
        speechProviderID = d.string(forKey: "speechProvider") ?? SpeechProvider.system.rawValue
        googleVoice = d.string(forKey: "googleVoice") ?? "Charon"
        speechSpeed = d.object(forKey: "speechSpeed") as? Double ?? 1.0
        dictationLanguage = d.string(forKey: "dictationLanguage") ?? "en"
        dictationPolish = d.object(forKey: "dictationPolish") as? Bool ?? true
        dictationTranslateHebrew = d.bool(forKey: "dictationTranslateHebrew")
        dictationWords = d.string(forKey: "dictationWords") ?? ""
        clipboardOnOpen = d.object(forKey: "clipboardOnOpen") as? Bool ?? true
        clipboardDays = d.object(forKey: "clipboardDays") as? Int ?? 30
        snippets = Prefs.snippets(d)
        refreshKeys()
    }

    var context: WritingContext { WritingContext(rawValue: contextID) ?? .chat }
    var speechProvider: SpeechProvider { SpeechProvider(rawValue: speechProviderID) ?? .system }

    func style(for context: WritingContext) -> String {
        styles[context.rawValue] ?? WritingContext.defaultStyle[context] ?? ""
    }

    func setStyle(_ text: String, for context: WritingContext) {
        styles[context.rawValue] = text
    }

    func setAPIKey(_ key: String) {
        Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), Keychain.anthropic)
        refreshKeys()
    }

    func speechKey(for provider: SpeechProvider) -> String {
        switch provider {
        case .google: return Keychain.read(Keychain.google) ?? ""
        case .elevenLabs: return Keychain.read(Keychain.elevenLabs) ?? ""
        case .system: return ""
        }
    }

    func setSpeechKey(_ key: String, for provider: SpeechProvider) {
        switch provider {
        case .google: Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), Keychain.google)
        case .elevenLabs: Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), Keychain.elevenLabs)
        case .system: break
        }
        refreshKeys()
    }

    func refreshKeys() {
        hasAPIKey = !(Keychain.read(Keychain.anthropic) ?? "").isEmpty
        hasSpeechKey = !speechKey(for: speechProvider).isEmpty
        keyboardReady = d.object(forKey: "keyboardSeen") != nil
    }

    /// The Lex keyboard has opened with Full Access at least once (it notes that in the app group).
    @Published private(set) var keyboardReady = false
}

/// Lex's look on iPhone: the indigo and orange of the app icon.
enum Brand {
    static let indigo = Color(red: 0.36, green: 0.30, blue: 0.92)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let tagline = "Fix, rewrite, translate, summarize and read aloud, with Claude."
    static let repo = URL(string: "https://github.com/matanweks/Lex")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
