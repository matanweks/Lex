import LexCore
import UIKit

/// An article the share sheet hands to the app, which reads it aloud, summarizes and translates
/// it where it can keep playing with the phone locked. It carries the page's text when Safari
/// gave it (so a page you're logged in to, or a paywalled one you can see, reads the same), or
/// just the link. It waits in the Keychain group until the app takes it.
enum ArticleInbox {
    struct Item: Codable {
        var url: String
        var article: Article? = nil
    }

    static let openURL = URL(string: "lex://article")!
    private static let account = "article.pending"

    static func put(_ item: Item) {
        Keychain.writeData(try? JSONEncoder().encode(item), account)
    }

    /// The waiting article, once.
    static func take() -> Item? {
        guard let data = Keychain.readData(account) else { return nil }
        Keychain.writeData(nil, account)
        return try? JSONDecoder().decode(Item.self, from: data)
    }
}

/// Opens the Lex app from an extension (the keyboard, the share sheet). Extensions have no API
/// for that, so this asks the app object at the end of the responder chain directly (fine for a
/// personal build; not App Store safe). False when there was no one to ask.
@MainActor @discardableResult
func openLexApp(_ url: URL, from start: UIResponder) -> Bool {
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = start
    while let current = responder {
        if current is UIApplication, current.responds(to: selector) {
            typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
            let open = unsafeBitCast(current.method(for: selector), to: Open.self)
            open(current, selector, url as NSURL, NSDictionary(), nil)
            return true
        }
        responder = current.next
    }
    return false
}
