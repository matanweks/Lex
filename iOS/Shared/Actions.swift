import Foundation
import LexCore
import SwiftUI

/// Something Lex does with a piece of text: the Mac's refine, translate, summarize and tone
/// actions in one list.
struct LexAction: Identifiable, Hashable {
    enum Kind { case rewrite, assist, toneNote }

    let id: String
    let label: String
    let symbol: String
    let kind: Kind
    let instruction: String

    init(_ refine: RefineAction, label: String? = nil, symbol: String, kind: Kind = .rewrite) {
        id = refine.id
        self.label = label ?? refine.label
        self.symbol = symbol
        self.kind = kind
        instruction = refine.instruction
    }

    static func refine(_ id: String) -> RefineAction {
        RefineAction.all.first { $0.id == id } ?? .improve
    }

    static let fix = LexAction(refine("fix"), label: "Fix mistakes", symbol: "checkmark.circle")
    static let improve = LexAction(.improve, symbol: "wand.and.stars")
    static let shorter = LexAction(refine("shorter"), symbol: "arrow.down.right.and.arrow.up.left")
    static let clearer = LexAction(refine("clearer"), symbol: "lightbulb")
    static let friendlier = LexAction(refine("friendlier"), symbol: "face.smiling")
    static let formal = LexAction(refine("formal"), symbol: "briefcase")
    static let direct = LexAction(refine("direct"), symbol: "arrow.right.circle")
    static let tone = LexAction(.tone, symbol: "heart.text.square")
    static let summary = LexAction(.summary, symbol: "text.append", kind: .assist)
    static let keyPoints = LexAction(.keyPoints, symbol: "list.bullet", kind: .assist)
    static let reply = LexAction(.reply, symbol: "arrowshape.turn.up.left", kind: .assist)
    static let toneCheck = LexAction(RefineAction(id: "tone-check", label: "How it sounds", instruction: ""), symbol: "ear", kind: .toneNote)

    static func translate(_ text: String) -> LexAction {
        LexAction(Translation.action(for: text), symbol: "character.bubble")
    }

    static func custom(_ instruction: String) -> LexAction {
        LexAction(.custom(instruction), symbol: "text.cursor")
    }

    /// For your own writing.
    static func forYourText(_ text: String) -> [LexAction] {
        [fix, improve, translate(text), shorter, clearer, friendlier, formal, direct, tone]
    }

    /// For text someone else wrote: an email, a thread, a page.
    static let forTheirText: [LexAction] = [summary, keyPoints, reply, toneCheck]

    /// Fixing mistakes is quick, so it gets the fast model; rewrites get the better one.
    func model(_ prefs: Prefs) -> ClaudeModel { id == "fix" ? prefs.quickModel : prefs.rewriteModel }
}

/// Runs actions through Claude, for the app, the share sheet and Shortcuts alike.
enum LexEngine {
    static let claude: ClaudeClient = {
        #if DEBUG
        if StubClaude.isOn { return ClaudeClient(apiKey: { "stub" }, protocolClasses: [StubClaude.self]) }
        #endif
        return ClaudeClient(apiKey: { Keychain.read(Keychain.anthropic) })
    }()

    /// The result, streamed to `onText` as it's written (the whole text so far each time).
    static func run(_ action: LexAction, on text: String, prefs: Prefs = .current,
                    onText: @escaping (String) -> Void = { _ in }) async throws -> String {
        let model = action.model(prefs)
        switch action.kind {
        case .rewrite:
            let result = try await claude.refine(text: text, context: "", instruction: action.instruction, model: model,
                                                 style: prefs.style, voice: prefs.voice, onText: onText)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        case .assist:
            let result = try await claude.assist(text: text, instruction: action.instruction, model: model, voice: prefs.voice, onText: onText)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        case .toneNote:
            let note = try await claude.toneNote(text, model: model)
            onText(note)
            return note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// One action on one piece of text, for a screen to show while it streams in.
@MainActor
final class ActionRun: ObservableObject {
    enum Phase: Equatable { case idle, running, done, failed(String) }

    @Published private(set) var action: LexAction?
    @Published private(set) var output = ""
    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    /// The result replaces text (a rewrite) rather than being a note about it.
    var isRewrite: Bool { action?.kind == .rewrite }

    func start(_ action: LexAction, on text: String) {
        cancel()
        self.action = action
        output = ""
        phase = .running
        task = Task {
            do {
                let result = try await LexEngine.run(action, on: text) { partial in
                    Task { @MainActor in if self.action == action, self.phase == .running { self.output = partial } }
                }
                guard !Task.isCancelled else { return }
                output = result
                phase = .done
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running { phase = .idle }
    }

    func reset() {
        cancel()
        action = nil
        output = ""
        phase = .idle
    }
}
