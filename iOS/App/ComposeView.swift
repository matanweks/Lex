import LexCore
import SwiftUI

/// What you're writing, kept between launches.
@MainActor
final class ComposeModel: ObservableObject {
    @Published var text: String { didSet { LocalStore.defaults.set(text, forKey: "draft") } }
    @Published var selection: TextSelection?
    /// Test support: an audio file to dictate, set by a `lex://debug` link.
    @Published var dictationFile: URL?

    init() {
        text = LocalStore.defaults.string(forKey: "draft") ?? ""
    }

    /// The selected range, when something is selected.
    var selectedRange: Range<String.Index>? {
        guard let selection, case .selection(let range) = selection.indices, !range.isEmpty, range.upperBound <= text.endIndex else { return nil }
        return range
    }

    /// Where the cursor is, or the end when the editor hasn't been touched.
    var caret: String.Index {
        guard let selection, case .selection(let range) = selection.indices, range.upperBound <= text.endIndex else { return text.endIndex }
        return range.lowerBound
    }

    /// Types `new` at the cursor (over the selection, if there is one) and puts the cursor after it.
    func insert(_ new: String) {
        let range: Range<String.Index>
        if let selected = selectedRange {
            range = selected
        } else {
            range = caret..<caret
        }
        let typed = range.isEmpty && range.lowerBound > text.startIndex
            ? DictationText.spaced(new, after: text[text.index(before: range.lowerBound)])
            : new
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + typed.count
        text.replaceSubrange(range, with: typed)
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: min(offset, text.count)))
    }
}

/// The Write tab: a notepad with Lex's actions, dictation and read aloud.
struct ComposeView: View {
    @ObservedObject var compose: ComposeModel
    @ObservedObject var settings: LexSettings
    @StateObject private var run = ActionRun()
    @StateObject private var reader = Reader()
    @StateObject private var dictation = DictationModel()
    @State private var target: Target?
    @State private var copied = false
    @FocusState private var editing: Bool

    /// The text the actions sheet works on: the selection, or everything.
    struct Target: Identifiable {
        let id = UUID()
        let text: String
        let range: Range<String.Index>?
        let whole: String
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $compose.text, selection: $compose.selection)
                .focused($editing)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if compose.text.isEmpty {
                        Text("Write, paste or dictate here. Then tap Lex to fix, rewrite, translate or summarize it.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("editor")
                .safeAreaInset(edge: .bottom) { bottomBar }
                .navigationTitle("Lex")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .sheet(item: $target) { target in actionsSheet(target) }
                .alert("Dictation", isPresented: Binding(get: { dictation.problem != nil }, set: { if !$0 { dictation.problem = nil } })) {
                    Button("OK") { dictation.problem = nil }
                } message: {
                    Text(dictation.problem ?? "")
                }
                .onChange(of: compose.dictationFile) { _, url in
                    guard let url else { return }
                    compose.dictationFile = nil
                    #if DEBUG
                    dictateFile(url)
                    #endif
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Writing for", selection: $settings.contextID) {
                    ForEach(WritingContext.allCases) { Text($0.shortLabel).tag($0.rawValue) }
                }
            } label: {
                Label(settings.context.shortLabel, systemImage: "text.bubble")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editing {
                Button("Done") { editing = false }
            }
            Menu {
                Button(copied ? "Copied" : "Copy All", systemImage: "doc.on.doc") {
                    ClipboardLog.copy(compose.text)
                    copied = true
                }
                .disabled(compose.text.isEmpty)
                Button("Clear", systemImage: "trash", role: .destructive) {
                    compose.text = ""
                    compose.selection = nil
                }
                .disabled(compose.text.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if dictation.isBusy {
                DictationBar(model: dictation, onStop: finishDictation, onCancel: dictation.cancel)
            }
            HStack(spacing: 12) {
                Button {
                    if dictation.phase == .listening { finishDictation() } else { startDictation() }
                } label: {
                    Image(systemName: dictation.phase == .listening ? "stop.fill" : "mic.fill")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(dictation.phase == .listening ? Brand.orange : Color.primary.opacity(0.08)))
                        .foregroundStyle(dictation.phase == .listening ? .white : .primary)
                }
                .accessibilityLabel(dictation.phase == .listening ? "Stop dictating" : "Dictate")
                .accessibilityIdentifier("mic")
                .disabled(dictation.phase != .idle && dictation.phase != .listening)

                Menu {
                    Picker("Dictation language", selection: $settings.dictationLanguage) {
                        Text("English").tag("en")
                        Text("Hebrew").tag("he")
                    }
                } label: {
                    Text(settings.dictationLanguage == "he" ? "עב" : "EN")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().strokeBorder(Color.secondary.opacity(0.4)))
                }
                .accessibilityLabel("Dictation language")

                Spacer()

                ReadAloudButton(reader: reader, text: compose.selectedRange.map { String(compose.text[$0]) } ?? compose.text)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)

                Button {
                    openActions()
                } label: {
                    Label("Lex", systemImage: "sparkles")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .frame(height: 52)
                        .background(Capsule().fill(Brand.indigo))
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("lex")
                .disabled(compose.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.bar)
    }

    private func actionsSheet(_ target: Target) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(target.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ActionsPanel(text: target.text, run: run, reader: reader,
                                 onReplace: { replace(target, with: $0) },
                                 onCopy: { ClipboardLog.copy($0) })
                }
                .padding()
            }
            .navigationTitle(target.range == nil ? "Your text" : "Selected text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { self.target = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear { run.reset() }
    }

    private func openActions() {
        editing = false
        run.reset()
        if let range = compose.selectedRange {
            target = Target(text: String(compose.text[range]), range: range, whole: compose.text)
        } else {
            target = Target(text: compose.text, range: nil, whole: compose.text)
        }
    }

    /// Puts a rewrite where its text came from: the selection, or everything.
    private func replace(_ target: Target, with new: String) {
        if let range = target.range {
            if compose.text == target.whole {
                compose.text.replaceSubrange(range, with: new)
            } else if let found = compose.text.range(of: target.text) {
                compose.text.replaceSubrange(found, with: new)
            } else {
                ClipboardLog.copy(new)
            }
        } else {
            compose.text = new
        }
        compose.selection = nil
        self.target = nil
    }

    private func startDictation() {
        Task { await dictation.start(language: settings.dictationLanguage) }
    }

    private func finishDictation() {
        let before = String(compose.text[..<compose.caret])
        Task {
            if let text = await dictation.stop(before: before) { compose.insert(text) }
        }
    }

    #if DEBUG
    private func dictateFile(_ url: URL) {
        let before = String(compose.text[..<compose.caret])
        Task {
            if let text = await dictation.dictate(file: url, language: settings.dictationLanguage, before: before) { compose.insert(text) }
        }
    }
    #endif
}

extension WritingContext {
    /// The picker's name for it on iPhone.
    var shortLabel: String {
        switch self {
        case .chat: return "Chat"
        case .email: return "Email"
        case .documents: return "Document"
        case .other: return "Anything"
        }
    }
}
