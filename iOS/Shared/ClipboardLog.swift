import LexCore
import UIKit

/// The clipboard history on disk, shared by the app and the share sheet. iPhone apps can't
/// watch the clipboard, so entries come from what Lex copies itself and what the app finds on
/// the clipboard when it opens.
enum ClipboardLog {
    static var directory: URL { AppGroup.container.appendingPathComponent("Clipboard", isDirectory: true) }

    static func store() -> ClipboardStore {
        let days = AppGroup.defaults.object(forKey: "clipboardDays") as? Int ?? 30
        let store = ClipboardStore(directory: directory, retention: TimeInterval(days) * 86400)
        store.load()
        return store
    }

    /// The clipboard's change count when Lex last looked, so the same copy isn't read twice.
    static var seenChangeCount: Int {
        get { AppGroup.defaults.integer(forKey: "clipboardChangeCount") }
        set { AppGroup.defaults.set(newValue, forKey: "clipboardChangeCount") }
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
}
