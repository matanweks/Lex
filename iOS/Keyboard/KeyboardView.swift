import LexCore
import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var run: ActionRun
    @ObservedObject var typist: Typist
    let controller: UIInputViewController

    var body: some View {
        VStack(spacing: 4) {
            topBar
                .frame(height: 40)
                .padding(.horizontal, 6)
            Group {
                if model.mic != .off {
                    listening.padding(.horizontal, 6)
                } else if run.action != nil {
                    result.padding(.horizontal, 6)
                } else if model.panel == .tools {
                    tools.padding(.horizontal, 6)
                } else if model.panel == .emoji {
                    emoji
                } else {
                    KeyGrid(look: typist.look, typist: typist)
                        .accessibilityIdentifier("kb-keys")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .tint(Brand.indigo)
    }

    // MARK: The Lex row

    /// Over the keys: Lex's tools, the suggestions (or Claude's fixes), and the mic. Over a
    /// panel: the way back to the keys.
    @ViewBuilder
    private var topBar: some View {
        if model.panel != nil || model.mic != .off || run.action != nil {
            HStack(spacing: 8) {
                barButton("keyboard", label: "Back to the keys") {
                    if model.mic != .off { model.cancelMic() }
                    if run.action != nil { model.close() }
                    model.panel = nil
                }
                if model.panel == .tools, model.mic == .off, run.action == nil {
                    header
                } else {
                    Text(model.panel == .emoji ? "Emoji" : "Lex").font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }
        } else {
            HStack(spacing: 6) {
                if controller.needsInputModeSwitchKey {
                    GlobeKey(controller: controller).frame(width: 38, height: 34)
                }
                barButton(model.hasFullAccess ? "sparkles" : "lock", label: "Lex tools", tint: Brand.indigo) { model.panel = .tools }
                    .accessibilityIdentifier("kb-lex")
                strip
                    .frame(maxWidth: .infinity)
                barButton("mic.fill", label: "Dictate") { model.micTapped() }
                    .disabled(!model.hasFullAccess)
                    .accessibilityIdentifier("kb-mic")
            }
        }
    }

    /// Claude's fixes when it found some, otherwise the word suggestions.
    @ViewBuilder
    private var strip: some View {
        if let fix = typist.fixes.first {
            HStack(spacing: 6) {
                Button { typist.apply([fix]) } label: {
                    HStack(spacing: 4) {
                        Text(fix.original).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2)
                        Text(fix.replacement.isEmpty ? "remove" : fix.replacement).fontWeight(.semibold)
                    }
                    .lineLimit(1)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Capsule().fill(Brand.indigo.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kb-fix")
                if typist.fixes.count > 1 {
                    Button("Fix all \(typist.fixes.count)") { typist.apply(typist.fixes) }
                        .font(.callout.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.indigo)
                }
                Spacer(minLength: 0)
                Button { typist.dismissFixes() } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        } else if model.canUndo {
            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    .font(.callout.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.indigo)
                Spacer()
            }
        } else if let notice = model.notice {
            Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        } else if typist.fieldIsEmpty, model.hasFullAccess {
            // Like Gboard's toolbar on an empty field: shortcuts instead of words.
            HStack(spacing: 0) {
                shortcut("arrowshape.turn.up.left", "Reply to copied") { model.performOnClipboard(.reply) }
                shortcut("list.clipboard", "Clipboard") { model.tab = .clipboard; model.panel = .tools }
                shortcut("text.badge.plus", "Snippets") { model.tab = .snippets; model.panel = .tools }
                shortcut("face.smiling", "Emoji") { model.panel = .emoji }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(typist.suggestions.enumerated()), id: \.element) { i, suggestion in
                    if i > 0 { Divider().frame(height: 22) }
                    Button { typist.choose(suggestion) } label: {
                        Text(suggestion.kind == .keep ? "“\(suggestion.text)”" : suggestion.text)
                            .font(.system(size: 17, weight: suggestion.best ? .semibold : .regular))
                            .foregroundStyle(suggestion.kind == .keep ? .secondary : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if typist.suggestions.isEmpty, typist.checking {
                    Text("Checking…").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func shortcut(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func barButton(_ symbol: String, label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Lex's tools

    @ViewBuilder
    private var tools: some View {
        if !model.hasFullAccess {
            fullAccessHelp
        } else {
            switch model.tab {
            case .lex: actions
            case .clipboard: clipboard
            case .snippets: snippetList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(KeyboardModel.Tab.allCases, id: \.self) { tab in
                Button(tab.rawValue) { model.tab = tab }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(model.tab == tab ? Brand.indigo.opacity(0.25) : .clear))
                    .foregroundStyle(model.tab == tab ? Brand.indigo : .secondary)
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if model.canUndo {
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.indigo)
            }
            Text(model.notice ?? targetLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 28)
    }

    private var targetLabel: String {
        guard let target = model.target else { return "Select text to work on" }
        let words = "\(target.text.words) word\(target.text.words == 1 ? "" : "s")"
        return target.source == .selection ? "Selection · \(words)" : "Before the cursor · \(words)"
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.hasKey {
                Text("Open the Lex app and add your Anthropic API key.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(yourActions) { action in
                    key(action.label, action.symbol) { model.perform(action) }
                        .accessibilityIdentifier("kb-\(action.id)")
                }
            }
            Text("Copied message")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 2)
            HStack(spacing: 6) {
                key("Reply to it", "arrowshape.turn.up.left", wide: true) { model.performOnClipboard(.reply) }
                    .accessibilityIdentifier("kb-reply")
                key("Summarize it", "text.append", wide: true) { model.performOnClipboard(.summary) }
            }
            HStack(spacing: 8) {
                SettingChip(title: "Autocorrect", key: "autocorrect")
                SettingChip(title: "Check sentences", key: "checkSentences")
                Spacer()
                Button("Forget my words") { typist.forgetWords() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .disabled(!model.hasKey)
    }

    private var yourActions: [LexAction] {
        let translate = LexAction.translate(model.target?.text.core ?? "")
        return [.fix, .improve, translate, .cleanUp, .shorter, .friendlier, .formal, .tone]
    }

    // MARK: The result

    private var result: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(run.action?.label ?? "", systemImage: run.action?.symbol ?? "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.indigo)
                if run.phase == .running { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    model.close()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }
            ScrollView {
                Group {
                    if case .failed(let message) = run.phase {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text(run.output.isEmpty ? "Writing…" : run.output)
                            .foregroundStyle(run.output.isEmpty ? .secondary : .primary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("kb-result")
            }
            .scrollEdgeEffectHidden()
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemBackground).opacity(0.7)))
            HStack(spacing: 8) {
                if run.action?.kind != .toneNote {
                    Button(model.resultTarget == .clipboard ? "Insert" : "Replace") { model.apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(run.phase != .done)
                        .accessibilityIdentifier("kb-apply")
                }
                Button("Copy") { model.copyResult() }
                    .buttonStyle(.bordered)
                    .disabled(run.phase != .done)
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Dictation

    private var listening: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(model.mic == .listening ? Brand.orange : Color.secondary).frame(width: 10, height: 10)
                Text(micStatus).font(.subheadline.weight(.semibold))
                if model.mic == .finishing { ProgressView().controlSize(.small) }
                Spacer()
                Text(model.micLanguage == "he" ? "עברית" : "English").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(micBody)
                    .font(.callout)
                    .foregroundStyle(model.micText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("kb-mic-text")
            }
            .scrollEdgeEffectHidden()
            .defaultScrollAnchor(.bottom)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemBackground).opacity(0.7)))
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelMic() }
                    .buttonStyle(.bordered)
                Spacer()
                if model.mic == .listening {
                    Button("Done") { model.micTapped() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("kb-mic-done")
                } else if model.mic == .opening {
                    Button("Open Lex") { model.micTapped() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var micStatus: String {
        switch model.mic {
        case .opening: return "Starting the mic…"
        case .listening: return "Listening"
        case .finishing: return "Writing it down…"
        case .off: return ""
        }
    }

    private var micBody: String {
        if !model.micText.isEmpty { return model.micText }
        switch model.mic {
        case .opening: return "Lex opens for a moment to start the microphone. Then tap ◀ at the top left to come back here, and talk."
        case .listening: return "Talk, then tap Done."
        default: return ""
        }
    }

    // MARK: Clipboard and snippets

    private var clipboard: some View {
        list(empty: "Nothing saved yet. What you copy shows up here when Lex opens.") {
            ForEach(model.clips) { item in
                row(item.text, detail: item.date.formatted(.relative(presentation: .named)), pinned: item.pinned) {
                    model.type(model.text(of: item))
                }
            }
        }
    }

    private var snippetList: some View {
        list(empty: "Add snippets in the Lex app, under Settings › Snippets.") {
            ForEach(model.snippets) { snippet in
                row(snippet.text, detail: snippet.name, pinned: false) { model.type(snippet.text) }
            }
        }
    }

    @ViewBuilder
    private func list<Rows: View>(empty: String, @ViewBuilder rows: () -> Rows) -> some View {
        let isEmpty = model.tab == .clipboard ? model.clips.isEmpty : model.snippets.isEmpty
        if isEmpty {
            Text(empty)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
        } else {
            ScrollView {
                LazyVStack(spacing: 5) { rows() }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden()
        }
    }

    private func row(_ text: String, detail: String, pinned: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if pinned { Image(systemName: "pin.fill").foregroundStyle(Brand.orange) }
                    Text(detail)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(KeyBackground())
        }
        .buttonStyle(.plain)
    }

    // MARK: Keys

    private func key(_ label: String, _ symbol: String, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if wide {
                    Label(label, systemImage: symbol).font(.footnote.weight(.medium))
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: symbol).font(.system(size: 17))
                        Text(label).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: wide ? 38 : 50)
            .background(KeyBackground())
        }
        .buttonStyle(.plain)
    }

    // MARK: Emoji

    private var emoji: some View {
        VStack(spacing: 6) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 4) {
                    ForEach(emojiList, id: \.self) { e in
                        Button {
                            typist.type(e)
                            model.usedEmoji(e)
                        } label: {
                            Text(e).font(.system(size: 30)).frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollEdgeEffectHidden()
            HStack(spacing: 6) {
                Button { model.panel = nil } label: {
                    Text(typist.language == .english ? "ABC" : "אבג").font(.callout).frame(width: 64, height: 40).background(KeyBackground(dim: true))
                }
                .buttonStyle(.plain)
                Button { typist.press(.space) } label: {
                    Text("space").font(.callout).frame(maxWidth: .infinity).frame(height: 40).background(KeyBackground())
                }
                .buttonStyle(.plain)
                Button { typist.press(.delete) } label: {
                    Image(systemName: "delete.left").frame(width: 64, height: 40).background(KeyBackground(dim: true))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
            .padding(.horizontal, 6)
        }
    }

    /// Yours first, then the ones people use most.
    private var emojiList: [String] {
        model.recentEmoji + Self.popularEmoji.filter { !model.recentEmoji.contains($0) }
    }

    private static let popularEmoji: [String] = {
        var seen = Set<String>()
        return "😂❤️🤣👍😭🙏😘🥰😍😊🎉😁💕🥺😅🔥☺️🤦‍♂️🤷‍♀️🙄😆🤗😉🎂🤔👏🙂😳🥳😎👌💜😔💪✨💖👀😋😏😢👉😩💯🌹💙😃😡💐😜🙈🤞😄🤤🙌🤪😀💋💀👇💔😌🤩🙃😬😱😴🤭😐🌞😒😇🌸😈🎶✌️🎊🥵😞💚☀️🖤💰😚👑🎁💥🙋☹️😑🥴👈✅👋🤢🌟❗😥🌈💛😝😫😲🔴🌻🤯💃👊🏃😕☕🍀💦⭐🦋🤨🌺🤘🌷💝💤🤝🐰😓🍻😟😣🧐😠🤠😻🌙😛🤙🙊".map(String.init).filter { seen.insert($0).inserted }
    }()

    private var fullAccessHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Lex needs Full Access", systemImage: "lock.open").font(.headline)
            Text("To reach Claude and your snippets, open Settings › General › Keyboard › Keyboards › Lex and turn on Allow Full Access. Lex only reads the field when you tap an action.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A setting the keyboard keeps for itself (the app's settings can't reach it without an app group).
private struct SettingChip: View {
    let title: String
    let key: String
    @State private var on: Bool

    init(title: String, key: String) {
        self.title = title
        self.key = key
        _on = State(initialValue: UserDefaults.standard.object(forKey: key) as? Bool ?? true)
    }

    var body: some View {
        Button {
            on.toggle()
            UserDefaults.standard.set(on, forKey: key)
        } label: {
            Label(title, systemImage: on ? "checkmark.circle.fill" : "circle").font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Brand.indigo : .secondary)
    }
}

/// A key's rounded background, light like the system's letter keys or dim like its function keys.
private struct KeyBackground: View {
    var dim = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(scheme == .dark ? Color(white: dim ? 0.27 : 0.42) : (dim ? Color(white: 0.68) : .white))
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
    }
}

/// The 🌐 key: tap for the next keyboard, hold for the list. It has to be a UIKit control,
/// since the system reads its touches.
private struct GlobeKey: UIViewRepresentable {
    let controller: UIInputViewController

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}
