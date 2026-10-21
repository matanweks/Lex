import LexCore
import UIKit

/// The clipboard history, shared by the app, the keyboard and the share sheet through the
/// Keychain group. iPhone apps can't watch the clipboard, so entries come from what Lex copies
/// itself and what the app or the keyboard finds on the clipboard when they open.
enum ClipboardLog {
    static func store() -> ClipboardStore {
        let days = SharedDefaults.standard.object(forKey: "clipboardDays") as? Int ?? 30
        // The Keychain isn't made for big items: fewer entries than on the Mac, no huge images.
        let store = ClipboardStore(storage: KeychainStorage(), retention: TimeInterval(days) * 86400, maxItems: 300, maxBytes: 3_000_000)
        moveIn(to: store)
        store.load()
        return store
    }

    /// The clipboard's change count when Lex last looked, so the same copy isn't read twice.
    static var seenChangeCount: Int {
        get { SharedDefaults.standard.integer(forKey: "clipboardChangeCount") }
        set { SharedDefaults.standard.set(newValue, forKey: "clipboardChangeCount") }
    }

    /// Puts text on the clipboard and in the history.
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
        seenChangeCount = UIPasteboard.general.changeCount
        store().add(data(text: text), appID: Bundle.main.bundleIdentifier, appName: "Lex")
    }

    static func data(text: String) -> ClipData {
        [[ClipTypes.plainText: Data(text.utf8)]]
    }

    /// Entries this target saved in its own folder before the history was shared, moved in
    /// once (oldest first, so the order stays), then removed from the folder.
    private static func moveIn(to store: ClipboardStore) {
        let folder = LocalStore.folder.appendingPathComponent("Clipboard", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let old = ClipboardStore(directory: folder, retention: .infinity, maxItems: .max)
        old.load()
        store.load()
        for item in old.items.reversed() {
            guard let data = old.data(for: item.id), let added = store.add(data, appID: item.appID, appName: item.appName, date: item.date) else { continue }
            if item.pinned, !added.pinned { store.togglePin(added.id) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The history's index and entries as Keychain items.
    private struct KeychainStorage: ClipboardStorage {
        func read(_ name: String) -> Data? { Keychain.readData("clip." + name) }
        func write(_ data: Data, as name: String) { Keychain.writeData(data, "clip." + name) }
        func remove(_ name: String) { Keychain.writeData(nil, "clip." + name) }
        func names() -> Set<String> { Set(Keychain.accounts(prefix: "clip.").map { String($0.dropFirst(5)) }) }
    }
}
