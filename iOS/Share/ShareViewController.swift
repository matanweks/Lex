import LexCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Lex in the share sheet: select text in any app, tap Share, then Lex. Shows the text with
/// Lex's actions; the result is copied back to paste where it belongs. A shared page or link
/// (an article in Safari, a post on X) goes to the Lex app's Read tab instead, to listen to,
/// summarize or translate.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { @MainActor in
            if let article = await Self.article(in: items) {
                ArticleInbox.put(article)
                model.article = true
                if openLexApp(ArticleInbox.openURL, from: self) {
                    try? await Task.sleep(for: .milliseconds(400))
                    extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }
            model.text = await Self.text(in: items)
            model.loaded = true
        }
    }

    /// A shared page or link, rather than text to work on. From Safari it comes with the page's
    /// text (the preprocessing script runs Readability in the page); posts on X are left to the
    /// app, which reads them through FxTwitter.
    static func article(in items: [NSExtensionItem]) async -> ArticleInbox.Item? {
        // Text that came along (a selection, or a few words around the link): text to work on
        // when it's more than a line about the link. Safari's page title doesn't count.
        let text = await attachedText(in: items)
        let hasPage = items.contains { item in
            (item.attachments ?? []).contains { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }
        }
        if !text.isEmpty, ArticleLink.find(in: text) == nil, !hasPage || text.split(whereSeparator: \.isWhitespace).count > 25 { return nil }
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
                guard let dict = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
                      let page = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                      let url = page["url"] as? String else { continue }
                let isXPost = URL(string: url).flatMap(ArticleLink.xPostID) != nil
                return ArticleInbox.Item(url: url, article: isXPost ? nil : Article(extracted: page))
            }
        }
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    return ArticleInbox.Item(url: url.absoluteString)
                }
            }
        }
        return ArticleLink.find(in: text).map { ArticleInbox.Item(url: $0.absoluteString) }
    }

    /// The plain-text attachments only (not the item's title).
    static func attachedText(in items: [NSExtensionItem]) async -> String {
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    /// The shared text: a plain-text attachment, or the item's own text (some apps send it that way).
    static func text(in items: [NSExtensionItem]) async -> String {
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            if let text = item.attributedContentText?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var text = ""
    @Published var loaded = false
    /// An article was handed to the app.
    @Published var article = false
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    let onDone: () -> Void
    @StateObject private var run = ActionRun()
    @StateObject private var reader = Reader()
    @State private var hasKey = !(Keychain.read(Keychain.anthropic) ?? "").isEmpty

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !hasKey && !LexEngine.claude.hasKey {
                        Label("Open the Lex app and add your Anthropic API key first.", systemImage: "key")
                            .foregroundStyle(.orange)
                    }
                    if model.article {
                        Label("The article is waiting in the Lex app. Open Lex and it's in the Read tab.", systemImage: "newspaper")
                    } else if model.loaded && model.text.isEmpty {
                        Text("Lex works on text. Select some text, then share it.").foregroundStyle(.secondary)
                    } else {
                        TextEditor(text: $model.text)
                            .font(.callout)
                            .frame(minHeight: 70, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                            .accessibilityIdentifier("shared-text")
                        ActionsPanel(text: model.text, run: run, reader: reader, onReplace: nil) { result in
                            ClipboardLog.copy(result)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Lex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        reader.stop()
                        run.cancel()
                        onDone()
                    }
                }
            }
        }
        .tint(Brand.indigo)
    }
}
