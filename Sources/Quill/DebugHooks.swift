import AppKit
import QuillCore

/// Test hooks so Quill can be driven from a script:
///   post the distributed notification "dev.quill.debug" with a command as its object.
/// Only installed when debug logging is on. Commands that touch a text field only act
/// when TextEdit is frontmost, so a stray trigger can never edit a real conversation.
final class DebugHooks {
    private let engine: Engine
    private let refine: RefineController
    private let client: ClaudeClient
    private let openRefine: (RefineScope) -> Void

    init(engine: Engine, refine: RefineController, client: ClaudeClient, openRefine: @escaping (RefineScope) -> Void) {
        self.engine = engine
        self.refine = refine
        self.client = client
        self.openRefine = openRefine
    }

    func install() {
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("dev.quill.debug"), object: nil, queue: .main) { [weak self] note in
            self?.run(note.object as? String ?? "")
        }
        Log.info("debug hooks installed")
    }

    /// The tracked field is a test field: in TextEdit, or text starting with the QUILLTEST marker
    /// (the local test pages). Never a field the user is really writing in.
    private var textEditFrontmost: Bool {
        guard let snap = engine.snapshot else { return false }
        return snap.bundleID == "com.apple.TextEdit" || snap.text.hasPrefix("QUILLTEST")
    }

    private func run(_ command: String) {
        Log.info("debug command: \(command)")
        switch command {
        case "benchmark":
            Task { await benchmark() }
        case "raw":
            Task {
                for s in ["The quarterly numbers looks good but we needs to improve retention.", "We should of left earlier, however we didnt."] {
                    var body: [String: Any] = [
                        "model": ClaudeModel.haiku.rawValue, "max_tokens": 1024,
                        "system": [["type": "text", "text": Prompts.checkSystem, "cache_control": ["type": "ephemeral"]]],
                        "messages": [["role": "user", "content": Prompts.checkUser(sentence: s, before: "", finished: true)]],
                    ]
                    var betas: [String] = []
                    ClaudeModel.haiku.applyLowLatency(to: &body, betas: &betas)
                    let t = try? await client.timed(body: body, betas: betas)
                    Log.info("raw | \(s) | \(t?.text.debugDescription ?? "error")")
                }
                Log.info("raw: done")
            }
        case "quality":
            Task { await quality() }
        case "apply-first" where textEditFrontmost:
            guard let issue = engine.issues.first, let fix = issue.replacements.first else { Log.info("no issue to apply"); return }
            Log.info("applying \(issue.kind.rawValue) fix")
            engine.apply(issue, replacement: fix)
        case "refine" where textEditFrontmost:
            openRefine(.sentence)
        case "refine-accept" where textEditFrontmost:
            refine.autoAcceptNext = true
            openRefine(.sentence)
        case "dump-field" where textEditFrontmost:
            // Test fields only (see textEditFrontmost), never the user's writing.
            Log.info("field text: \(engine.snapshot?.text.replacingOccurrences(of: "\n", with: "⏎") ?? "nil")")
            Log.info("issues: " + engine.issues.map { "\($0.source.rawValue)/\($0.kind.rawValue) '\($0.original)'→'\($0.replacements.first ?? "")'" }.joined(separator: ", "))
        default:
            Log.info("ignored: unknown command, or the tracked field isn't TextEdit (it's \(engine.snapshot?.bundleID ?? "none"); frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
        }
    }

    // MARK: Benchmark (fixed sample text only, never the user's)

    private static let sentences = [
        "Their going to recieve the package tomorow.",
        "The quarterly numbers looks good but we needs to improve retention.",
        "Please let me know if you have any questions about the proposal.",
    ]

    private static let paragraphs = [
        "hey team, just wanted to give a quick update that we is going to push the release to next week because their are still a few bugs that needs fixing. sorry for the delay",
        "Following up on our call, I wanted to send over the pricing we discussed. Let me know if their are any question or if you want to loop in you're finance team.",
        "The integration are working now but it take about ten second to sync, which is to slow for the field teams.",
    ]

    static func median(_ xs: [Double]) -> Int { xs.isEmpty ? -1 : Int(xs.sorted()[xs.count / 2] * 1000) }

    private func benchmark() async {
        Log.info("benchmark: start")
        // Warm the connection so the first sample isn't penalised.
        _ = try? await client.check(sentence: "Warm up.", before: "", finished: true, model: .haiku)

        for model in [ClaudeModel.haiku, .sonnet] {
            var totals: [Double] = [], firsts: [Double] = []
            var edits = 0
            for _ in 0..<2 {
                for s in Self.sentences {
                    let start = Date()
                    var first: Double?
                    do {
                        let found = try await client.check(sentence: s, before: "", finished: true, model: model) { _ in
                            if first == nil { first = Date().timeIntervalSince(start) }
                        }
                        totals.append(Date().timeIntervalSince(start))
                        if let first { firsts.append(first) }
                        edits += found.count
                    } catch {
                        Log.info("bench check \(model.shortLabel): error \(error.localizedDescription)")
                    }
                }
            }
            Log.info("bench check \(model.shortLabel): total \(Self.median(totals)) ms | first underline \(Self.median(firsts)) ms | \(edits) edits over n=\(totals.count)")
        }

        // Is the check prompt actually being cached?
        var body: [String: Any] = [
            "model": ClaudeModel.haiku.rawValue,
            "max_tokens": 1024,
            "system": [["type": "text", "text": Prompts.checkSystem, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": Prompts.checkUser(sentence: Self.sentences[0], before: "", finished: true)]],
        ]
        var betas: [String] = []
        ClaudeModel.haiku.applyLowLatency(to: &body, betas: &betas)
        if let t = try? await client.timed(body: body, betas: betas) {
            Log.info("bench cache: \(t.cacheReadTokens) prompt tokens read from cache")
        }

        for model in ClaudeModel.allCases {
            await measure("refine \(model.shortLabel)", inputs: Self.paragraphs) { s in
                var body: [String: Any] = [
                    "model": model.rawValue,
                    "max_tokens": 8000,
                    "system": Prompts.refineSystem,
                    "messages": [["role": "user", "content": Prompts.refineUser(text: s, context: "", instruction: RefineAction.improve.instruction)]],
                ]
                var betas: [String] = []
                model.applyLowLatency(to: &body, betas: &betas)
                return (body, betas)
            }
        }
        Log.info("benchmark: done")
    }

    /// Logs what each model flags on fixed sample sentences (sample text only).
    private func quality() async {
        let samples = Self.sentences + [
            "I has a apple and it are red.",
            "We should of left earlier, however we didnt.",
            "Its a good idea to check you're work before sending it.",
        ]
        for model in [ClaudeModel.haiku, .sonnet] {
            for s in samples {
                var runs: [String] = []
                for _ in 0..<3 {
                    let found = (try? await client.check(sentence: s, before: "", finished: true, model: model)) ?? []
                    runs.append(found.map { "\($0.original)→\($0.replacement)" }.joined(separator: ", "))
                }
                Log.info("quality \(model.shortLabel) | \(s) | " + runs.joined(separator: "  ||  "))
            }
        }
        Log.info("quality: done")
    }

    private func measure(_ name: String, inputs: [String], rounds: Int = 2, make: (String) -> ([String: Any], [String])) async {
        var totals: [Double] = [], firsts: [Double] = [], tokens: [Int] = []
        for _ in 0..<rounds {
            for s in inputs {
                let (body, betas) = make(s)
                do {
                    let t = try await client.timed(body: body, betas: betas)
                    totals.append(t.total); firsts.append(t.firstText); tokens.append(t.outputTokens)
                } catch {
                    Log.info("bench \(name): error \(error.localizedDescription)")
                }
            }
        }
        let avgTokens = tokens.isEmpty ? 0 : tokens.reduce(0, +) / tokens.count
        Log.info("bench \(name): total \(Self.median(totals)) ms | first text \(Self.median(firsts)) ms | ~\(avgTokens) out tokens | n=\(totals.count)")
    }
}
