import LexCore
import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var run: ActionRun
    let controller: UIInputViewController

    var body: some View {
        VStack(spacing: 6) {
            if !model.hasFullAccess {
                fullAccessHelp
            } else if run.action != nil {
                result
            } else {
                header
                switch model.tab {
                case .lex: actions
                case .clipboard: clipboard
                case .snippets: snippetList
                }
            }
            bottomRow
        }
        .padding(.horizontal, 5)
        .padding(.top, 6)
        .padding(.bottom, 3)
        .tint(Brand.indigo)
    }

    // MARK: Top

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

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if controller.needsInputModeSwitchKey {
                GlobeKey(controller: controller)
                    .frame(width: 44, height: 42)
                    .background(KeyBackground(dim: true))
            }
            Button { model.key(" ") } label: {
                Text("space").font(.callout).frame(maxWidth: .infinity).frame(height: 42).background(KeyBackground())
            }
            .buttonStyle(.plain)
            Button { model.key(nil) } label: {
                Image(systemName: "delete.left").frame(width: 52, height: 42).background(KeyBackground(dim: true))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
            Button { model.key("\n") } label: {
                Image(systemName: "return").frame(width: 52, height: 42).background(KeyBackground(dim: true))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return")
        }
    }

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
