import LexCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Lex in the share sheet: select text in any app, tap Share, then Lex. Shows the text with
/// Lex's actions; the result is copied back to paste where it belongs.
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
            model.text = await Self.text(in: items)
            model.loaded = true
        }
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
                    if model.loaded && model.text.isEmpty {
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
