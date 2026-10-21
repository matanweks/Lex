import Foundation
import LexCore
import Security
import SwiftUI

/// Each Lex target's own storage: the app's draft and welcome, the read-aloud cache. What the
/// targets share (settings, snippets, the clipboard history, keys) is in the Keychain group
/// instead, since a free developer account can't give them an app group. The name is the app
/// group Lex used before, so what was saved there is still found and moved over.
enum LocalStore {
    static let defaults = UserDefaults(suiteName: "group.dev.lex.ios") ?? .standard

    static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
}

/// The Keychain group named in every Lex target's entitlements, so they all see the same items.
/// Readable after the first unlock, so Shortcuts work while the phone is locked.
enum Keychain {
    static let service = "dev.lex.app"
    static let anthropic = "anthropic-api-key"
    static let google = "google-tts-api-key"
    static let elevenLabs = "elevenlabs-api-key"

    /// Raw data in the shared Keychain group (the keyboard's voice link uses it).
    static func readData(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Updates the item in place (it changes several times a second while dictating), or
    /// removes it for nil.
    static func writeData(_ data: Data?, _ account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let data else {
            SecItemDelete(match as CFDictionary)
            return
        }
        if SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// The accounts saved that start with `prefix`.
    static func accounts(prefix: String) -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) })
    }

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

/// Settings every Lex target reads, kept like `UserDefaults` keeps them but in the shared
/// Keychain group, one item per setting (so two targets saving different settings at once
/// can't undo each other).
struct SharedDefaults: Sendable {
    static let standard = SharedDefaults()

    private func account(_ key: String) -> String { "pref." + key }

    func object(forKey key: String) -> Any? {
        guard let data = Keychain.readData(account(key)),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any] else { return nil }
        return list.first
    }

    /// Nil removes the setting.
    func set(_ value: Any?, forKey key: String) {
        guard let value else { return Keychain.writeData(nil, account(key)) }
        Keychain.writeData(try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0), account(key))
    }

    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    /// Settings this target saved for itself before they were shared, moved in once. A
    /// setting already shared (saved from another target) wins.
    static func moveIn(_ keys: [String], from old: UserDefaults) {
        guard !old.bool(forKey: "movedToKeychain") else { return }
        for key in keys {
            if let value = old.object(forKey: key), standard.object(forKey: key) == nil { standard.set(value, forKey: key) }
        }
        old.set(true, forKey: "movedToKeychain")
    }

    /// The app's settings, for `moveIn`.
    static let appKeys = ["refineModel", "liveModel", "context", "styles", "voiceProfile", "speechProvider", "googleVoice", "speechSpeed",
                          "dictationLanguage", "dictationPolish", "dictationTranslateHebrew", "dictationWords", "clipboardOnOpen",
                          "clipboardDays", "snippets"]
}

/// The settings as plain values, read fresh. Safe on any thread, so Shortcuts and the share
/// sheet use this rather than `LexSettings`.
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
        let d = SharedDefaults.standard
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

    /// Just the model for quick work, without reading every setting.
    static var quickModel: ClaudeModel { ClaudeModel(rawValue: SharedDefaults.standard.string(forKey: "liveModel") ?? "") ?? .haiku }

    /// Saved the same way as on the Mac (JSON under "snippets").
    static func snippets(_ d: SharedDefaults) -> [Snippet] {
        d.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }
}

/// The settings screen's view of the same values. Every change is saved straight away, where
/// `Prefs` and the other Lex targets read it.
final class LexSettings: ObservableObject {
    private let d = SharedDefaults.standard

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

    /// The Lex keyboard has opened with Full Access at least once (it notes that in the shared settings).
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

/// The keyboard's settings, like Gboard's. The keyboard's tools and the app's Settings both
/// change them; the keyboard reads them again each time it opens.
final class KeyboardSettings: ObservableObject {
    enum Height: Int, CaseIterable, Identifiable {
        case extraShort, short, normal, midTall, tall
        var id: Int { rawValue }
        var label: String { ["Extra short", "Short", "Normal", "Mid-tall", "Tall"][rawValue] }
        /// How tall the keys are, compared with normal.
        var scale: Double { [0.84, 0.92, 1.0, 1.08, 1.16][rawValue] }
    }

    /// One-handed mode: the keys narrower, against one side.
    enum Hand: String, CaseIterable { case off, left, right }

    private let d = SharedDefaults.standard
    private var loading = false

    @Published var autocorrect = true { didSet { save(autocorrect, "autocorrect") } }
    @Published var checkSentences = true { didSet { save(checkSentences, "checkSentences") } }
    /// Claude offers the rest of the sentence after a pause (Smart Compose).
    @Published var completeSentences = true { didSet { save(completeSentences, "completeSentences") } }
    @Published var numberRow = false { didSet { save(numberRow, "numberRow") } }
    @Published var height = Height.normal { didSet { save(height.rawValue, "keyboardHeight") } }
    @Published var sound = true { didSet { save(sound, "keySound") } }
    @Published var vibration = true { didSet { save(vibration, "keyVibration") } }
    @Published var hand = Hand.off { didSet { save(hand.rawValue, "oneHanded") } }

    init() { reload() }

    func reload() {
        loading = true
        defer { loading = false }
        autocorrect = d.object(forKey: "autocorrect") as? Bool ?? true
        checkSentences = d.object(forKey: "checkSentences") as? Bool ?? true
        completeSentences = d.object(forKey: "completeSentences") as? Bool ?? true
        numberRow = d.bool(forKey: "numberRow")
        height = Height(rawValue: d.object(forKey: "keyboardHeight") as? Int ?? Height.normal.rawValue) ?? .normal
        sound = d.object(forKey: "keySound") as? Bool ?? true
        vibration = d.object(forKey: "keyVibration") as? Bool ?? true
        hand = Hand(rawValue: d.string(forKey: "oneHanded") ?? "") ?? .off
    }

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        d.set(value, forKey: key)
    }
}
