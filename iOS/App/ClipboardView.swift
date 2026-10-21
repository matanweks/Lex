import LexCore
import SwiftUI
import UIKit

/// The clipboard history. iPhone apps can't watch the clipboard, so Lex saves what's on it
/// each time you open Lex, plus everything Lex copies itself (and the share sheet's copies).
@MainActor
final class ClipboardModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    private var store = ClipboardLog.store()

    func reload() {
        store = ClipboardLog.store()
        items = store.ordered
    }

    /// Saves what's on the clipboard if it changed since Lex last looked. iOS asks before
    /// letting Lex read it, unless Lex may paste from other apps (Settings › Apps › Lex).
    func captureIfChanged(enabled: Bool) {
        reload()
        let pasteboard = UIPasteboard.general
        guard enabled, pasteboard.changeCount != ClipboardLog.seenChangeCount else { return }
        ClipboardLog.seenChangeCount = pasteboard.changeCount
        guard pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages,
              ClipPolicy.shouldRecord(types: pasteboard.types, appID: nil, ignoredApps: []) else { return }
        var data: ClipData = []
        if let text = pasteboard.string {
            data = ClipboardLog.data(text: text)
        } else if let url = pasteboard.url {
            data = ClipboardLog.data(text: url.absoluteString)
        } else if let png = pasteboard.image?.pngData() {
            data = [[ClipTypes.png: png]]
        }
        guard !data.isEmpty else { return }
        store.add(data, appID: nil, appName: nil)
        items = store.ordered
    }

    /// Text from the Paste button (which iOS doesn't ask about).
    func save(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.add(ClipboardLog.data(text: text), appID: nil, appName: nil)
        ClipboardLog.seenChangeCount = UIPasteboard.general.changeCount
        items = store.ordered
    }

    func text(of item: ClipItem) -> String { store.fullText(for: item) }

    func image(of item: ClipItem) -> UIImage? {
        guard item.kind == .image, let data = store.data(for: item.id)?.first?[ClipTypes.png] else { return nil }
        return UIImage(data: data)
    }

    func copy(_ item: ClipItem) {
        if item.kind == .image, let image = image(of: item) {
            UIPasteboard.general.image = image
        } else {
            UIPasteboard.general.string = text(of: item)
        }
        ClipboardLog.seenChangeCount = UIPasteboard.general.changeCount
    }

    func togglePin(_ item: ClipItem) {
        store.togglePin(item.id)
        items = store.ordered
    }

    func remove(_ item: ClipItem) {
        store.remove(item.id)
        items = store.ordered
    }

    /// Removes everything except pinned entries.
    func clear() {
        store.clear()
        items = store.ordered
    }
}

struct ClipboardView: View {
    @ObservedObject var model: ClipboardModel
    @ObservedObject var settings: LexSettings
    /// Opens an entry's text in the Write tab.
    let onEdit: (String) -> Void
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var confirmClear = false

    private var shown: [ClipItem] { ClipboardStore.search(model.items, query) }

    var body: some View {
        NavigationStack {
            List {
                if !settings.clipboardOnOpen {
                    Text("Saving the clipboard is off. Turn it on in Settings › Clipboard.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(shown) { item in
                    row(item)
                        .contentShape(Rectangle())
                        .onTapGesture { copy(item) }
                        .swipeActions(edge: .leading) {
                            Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") { model.togglePin(item) }
                                .tint(Brand.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.remove(item) }
                        }
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { copy(item) }
                            if item.kind != .image {
                                Button("Edit in Lex", systemImage: "square.and.pencil") { onEdit(model.text(of: item)) }
                            }
                            Button(item.pinned ? "Unpin" : "Pin", systemImage: "pin") { model.togglePin(item) }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.remove(item) }
                        }
                }
                if !model.items.isEmpty {
                    Section {
                    } footer: {
                        Text("iPhone apps can't see what you copy in the background, so Lex saves the clipboard each time you open it. To stop iOS asking each time, open Settings › Apps › Lex and set Paste from Other Apps to Allow.")
                    }
                }
            }
            // The share sheet and Shortcuts add entries too.
            .onAppear { model.reload() }
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView("Nothing saved yet", systemImage: "list.clipboard",
                                           description: Text("iPhone apps can't see what you copy in the background. Lex saves the clipboard each time you open it, and everything Lex copies. Tap Paste to save what's on it now."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search what you copied")
            .navigationTitle("Clipboard")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in model.save(strings.joined(separator: "\n")) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .disabled(model.items.allSatisfy(\.pinned))
                }
            }
            .confirmationDialog("Clear the clipboard history? Pinned entries stay.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { model.clear() }
            }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = model.image(of: item) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: item.kind == .link ? "link" : "text.alignleft")
                    .foregroundStyle(Brand.indigo)
                    .frame(width: 22)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                if item.kind != .image {
                    Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines)).lineLimit(3)
                }
                HStack(spacing: 6) {
                    if item.pinned { Image(systemName: "pin.fill").foregroundStyle(Brand.orange) }
                    Text(copiedID == item.id ? "Copied" : item.date.formatted(.relative(presentation: .named)))
                    if let app = item.appName { Text("· \(app)") }
                }
                .font(.caption)
                .foregroundStyle(copiedID == item.id ? Brand.indigo : .secondary)
            }
        }
        .accessibilityIdentifier("clip-row")
    }

    private func copy(_ item: ClipItem) {
        model.copy(item)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == item.id { copiedID = nil }
        }
    }
}
