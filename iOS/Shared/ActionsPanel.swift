import LexCore
import SwiftUI

/// Lex's actions on a piece of text and the result as it streams in. The app shows it in a
/// sheet over what you're writing; the share sheet shows it over what you shared.
struct ActionsPanel: View {
    let text: String
    @ObservedObject var run: ActionRun
    @ObservedObject var reader: Reader
    /// The app's "Replace": puts a rewrite back where the text came from. Nil in the share sheet.
    var onReplace: ((String) -> Void)?
    var onCopy: (String) -> Void

    @State private var instruction = ""
    @State private var copied = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if run.action != nil {
                result
            }
            section("Your writing", LexAction.forYourText(text))
            section("Someone else's", LexAction.forTheirText)
            HStack {
                TextField("Or tell Lex what to change…", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .submitLabel(.go)
                    .onSubmit(runCustom)
                Button("Go", action: runCustom)
                    .buttonStyle(.borderedProminent)
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func section(_ title: String, _ actions: [LexAction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            FlowLayout(spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        typing = false
                        copied = false
                        run.start(action, on: text)
                    } label: {
                        Label(action.label, systemImage: action.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(run.action == action ? Brand.indigo.opacity(0.22) : Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("action-\(action.id)")
                }
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(run.action?.label ?? "", systemImage: run.action?.symbol ?? "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.indigo)
                Spacer()
                if run.phase == .running { ProgressView().controlSize(.small) }
            }
            switch run.phase {
            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.callout)
            default:
                Text(run.output.isEmpty ? "Writing…" : run.output)
                    .foregroundStyle(run.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("result")
            }
            if run.phase == .done {
                HStack(spacing: 10) {
                    if let onReplace, run.isRewrite {
                        Button("Replace") { onReplace(run.output) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("replace")
                    }
                    Button(copied ? "Copied" : "Copy") {
                        onCopy(run.output)
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("copy")
                    ReadAloudButton(reader: reader, text: run.output)
                        .buttonStyle(.bordered)
                        .labelStyle(.iconOnly)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.indigo.opacity(0.07)))
    }

    private func runCustom() {
        let said = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        typing = false
        copied = false
        run.start(.custom(said), on: text)
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
