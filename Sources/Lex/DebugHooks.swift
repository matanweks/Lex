import AppKit
import LexCore

/// Test hooks so Lex can be driven from a script:
///   post the distributed notification "dev.lex.debug" with a command as its object.
/// Only installed when debug logging is on. Commands that touch a text field only act
/// when TextEdit is frontmost, so a stray trigger can never edit a real conversation.
final class DebugHooks {
    private let engine: Engine
    private let refine: RefineController
    private let client: ClaudeClient
    private let openRefine: (RefineScope) -> Void
    private let reader: Reader
    private let speech: SpeechClient
    private let settings: AppSettings

    init(engine: Engine, refine: RefineController, client: ClaudeClient, reader: Reader, speech: SpeechClient, settings: AppSettings, openRefine: @escaping (RefineScope) -> Void) {
        self.engine = engine
        self.refine = refine
        self.client = client
        self.reader = reader
        self.speech = speech
        self.settings = settings
        self.openRefine = openRefine
    }

    func install() {
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("dev.lex.debug"), object: nil, queue: .main) { [weak self] note in
            self?.run(note.object as? String ?? "")
        }
        Log.info("debug hooks installed")
    }

    /// The tracked field is a test field: in TextEdit, or text starting with the LEXTEST marker
    /// (the local test pages). Never a field the user is really writing in.
    private var textEditFrontmost: Bool {
        guard let snap = engine.snapshot else { return false }
        return snap.bundleID == "com.apple.TextEdit" || snap.text.hasPrefix("LEXTEST")
    }

    private func run(_ command: String) {
        Log.info("debug command: \(command)")
        switch command {
        case "benchmark":
            Task { await benchmark() }
        case let c where c.hasPrefix("raw:"):
            // Claude's exact check output for a sample sentence (passed in by the tester).
            let sentence = String(c.dropFirst(4))
            Task {
                var body: [String: Any] = [
                    "model": ClaudeModel.haiku.rawValue, "max_tokens": 1024,
                    "system": [["type": "text", "text": Prompts.checkSystem, "cache_control": ["type": "ephemeral"]]],
                    "messages": [["role": "user", "content": Prompts.checkUser(sentence: sentence, before: "", finished: true)]],
                ]
                var betas: [String] = []
                ClaudeModel.haiku.applyLowLatency(to: &body, betas: &betas)
                for _ in 0..<3 {
                    let t = try? await client.timed(body: body, betas: betas)
                    Log.info("raw | \(t?.text.debugDescription ?? "error")")
                }
                Log.info("raw: done")
            }
        case let c where c.hasPrefix("speak:"):
            reader.read(String(c.dropFirst(6)))
        case let c where c.hasPrefix("speak-skip:"):
            reader.skip(TimeInterval(c.dropFirst("speak-skip:".count)) ?? 0)
        case "speak-stop":
            reader.stop()
        case "speak-state":
            Log.info("reader: phase=\(reader.model.phase) voice=\(reader.model.voice) chunk \(reader.model.index + 1)/\(reader.model.count) at \(String(format: "%.1f", reader.position)) s speed=\(reader.model.speed)")
        case "stt-test-apple":
            Task { await sttTest(engine: .apple) }
        case "stt-test-google":
            Task { await sttTest(engine: .google) }
        case "tts-bench":
            Task { await ttsBench() }
        case "think-bench":
            Task { await thinkBench() }
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
        case let c where c.hasPrefix("probe-app:"):
            engine.tracker.probeApp(bundleID: String(c.dropFirst("probe-app:".count)), enhance: false)
        case let c where c.hasPrefix("probe-app-enhanced:"):
            engine.tracker.probeApp(bundleID: String(c.dropFirst("probe-app-enhanced:".count)), enhance: true)
        case "compare-rects" where textEditFrontmost:
            if let snap = engine.snapshot { engine.tracker.compareRects(for: engine.issues, in: snap) }
        case "ax-probe":
            engine.tracker.probeGeometry(enhance: false)
        case "ax-probe-enhanced":
            engine.tracker.probeGeometry(enhance: true)
        case "quality":
            Task { await quality() }
        case "apply-first" where textEditFrontmost:
            guard let issue = engine.issues.first, let fix = issue.replacements.first else { Log.info("no issue to apply"); return }
            Log.info("applying \(issue.kind.rawValue) fix")
            engine.apply(issue, replacement: fix)
        case let c where c.hasPrefix("remove-word:") && textEditFrontmost:
            // Runs a removal through the real fix path, as if Claude had suggested deleting the word.
            guard let snap = engine.snapshot,
                  let issue = EditMapper.issues(for: [AIEdit(original: String(c.dropFirst("remove-word:".count)), replacement: "", kind: .grammar, reason: "test")], sentence: snap.text, base: 0).first
            else { Log.info("word not found"); return }
            engine.apply(issue, replacement: "")
        case let c where c.hasPrefix("fix:") && c.contains("=>") && textEditFrontmost:
            // Runs any fix through the real path, as if Claude had suggested it: fix:have idea=>have an idea
            let parts = String(c.dropFirst(4)).components(separatedBy: "=>")
            guard let snap = engine.snapshot,
                  let issue = EditMapper.issues(for: [AIEdit(original: parts[0], replacement: parts[1], kind: .grammar, reason: "test")], sentence: snap.text, base: 0).first
            else { Log.info("words not found"); return }
            engine.apply(issue, replacement: issue.replacements[0])
        case "fix-all" where textEditFrontmost:
            engine.fixAll()
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

    /// Dictation without a person: speak sample sentences with the Google voice, transcribe
    /// the audio, tidy it with Claude, and log what came out at each step (sample text only).
    private func sttTest(engine: DictationEngine) async {
        var samples = [("Um, so I think we should, uh, ship the update to Pelles on Tuesday, no wait, Wednesday. Can you let the team know?", "en")]
        if engine == .google { samples.append(("אממ, אני חושב שכדאי לשלוח את העדכון ביום שלישי, לא רגע, ביום רביעי. תעדכן את הצוות בבקשה.", "he")) }
        for (text, language) in samples {
            do {
                let request = SpeechClient.Request(text: text, provider: .google, key: settings.speechKey(for: .google) ?? "",
                                                   googleLocale: GoogleTTS.locale(for: language), googleVoice: "Charon", elevenVoiceID: "", elevenModel: .flash)
                let (mp3, _) = try await speech.synthesize(request)
                let audio = try PCMDecoder.decode(mp3)
                let t0 = Date()
                let raw = engine == .apple
                    ? try await AppleTranscription.transcribe(audio)
                    : try await speech.transcribe(audio, languages: settings.dictationLanguages.googleCodes, phrases: ["Pelles"])
                let heard = Int(Date().timeIntervalSince(t0) * 1000)
                let t1 = Date()
                let cleaned = try? await client.cleanDictation(raw, app: "Slack", before: "", words: ["Pelles"], model: .haiku)
                let tidied = Int(Date().timeIntervalSince(t1) * 1000)
                let final = DictationText.choose(cleaned: cleaned, raw: raw)
                Log.info("stt-test \(engine.rawValue) \(language): \(String(format: "%.1f", audio.seconds)) s audio | transcribed in \(heard) ms | tidied in \(tidied) ms")
                Log.info("stt-test raw: \(raw)")
                Log.info("stt-test final: \(final)")
            } catch {
                Log.info("stt-test \(engine.rawValue) \(language) error: \(error.localizedDescription)")
            }
        }
        Log.info("stt-test: done")
    }

    /// Times the configured cloud voice on sample text without playing it. Sample text carries a
    /// timestamp so the disk cache can't answer.
    private func ttsBench() async {
        let provider = settings.speechProvider
        let key = settings.speechKey(for: provider) ?? ""
        guard provider != .system, !key.isEmpty || (provider == .google && speech.googleSignedIn) else { Log.info("tts-bench: no cloud voice configured"); return }
        let stamp = Int(Date().timeIntervalSince1970)
        let samples = [
            "Hi! This is a short opening sentence, run \(stamp).",
            "Here is a longer passage that stands in for a typical paragraph you might select and listen to while reading an email or a document. It has a few sentences, run \(stamp), so the timing reflects real use.",
            "זה משפט בעברית לבדיקה, הרצה \(stamp).",
        ]
        // What a real read waits for: the first chunk of a typical paragraph.
        let paragraph = "When you finish writing a long email to the whole team, run \(stamp), Lex can read it back so you can hear how it sounds before you send it. It reads in chunks, so the audio starts quickly."
        for text in samples + [SpeechText.chunks(paragraph)[0]] {
            let started = Date()
            let request = SpeechClient.Request(text: text, provider: provider, key: key, googleLocale: GoogleTTS.locale(for: SpeechText.language(of: text)),
                                               googleVoice: settings.googleVoice, elevenVoiceID: settings.elevenVoiceID, elevenModel: settings.elevenModel)
            do {
                let (audio, _) = try await speech.synthesize(request)
                Log.info("tts-bench \(provider.rawValue) \(request.googleLocale): \(text.count) chars → \(audio.count / 1024) KB in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } catch {
                Log.info("tts-bench error: \(error.localizedDescription)")
            }
        }
        Log.info("tts-bench: done")
    }

    /// Haiku with thinking off vs adaptive thinking at low effort: speed, and how often the
    /// reply contains lines that aren't edits (thinking out loud). Sample text only.
    private func thinkBench() async {
        let samples = Self.sentences + ["Remove function still bla doesnt work.", "I has a apple and it are red.", "We should of left earlier, however we didnt."]
        for thinking in [false, true] {
            var totals: [Double] = [], firsts: [Double] = []
            var noisy = 0, runs = 0, edits = 0
            for _ in 0..<2 {
                for s in samples {
                    var body: [String: Any] = [
                        "model": ClaudeModel.haiku.rawValue, "max_tokens": 2048,
                        "system": [["type": "text", "text": Prompts.checkSystem, "cache_control": ["type": "ephemeral"]]],
                        "messages": [["role": "user", "content": Prompts.checkUser(sentence: s, before: "", finished: true)]],
                        "output_config": ["effort": "low"],
                    ]
                    if !thinking { body["thinking"] = ["type": "disabled"] }
                    guard let t = try? await client.timed(body: body, betas: []) else { continue }
                    runs += 1
                    totals.append(t.total); firsts.append(t.firstText)
                    let lines = t.text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    let parsed = lines.compactMap(EditLineParser.parse)
                    edits += parsed.count
                    if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) != "OK" && EditLineParser.parse($0) == nil }) { noisy += 1 }
                }
            }
            Log.info("think-bench thinking=\(thinking ? "adaptive/low" : "off"): total \(Self.median(totals)) ms | first text \(Self.median(firsts)) ms | noisy replies \(noisy)/\(runs) | edit lines \(edits)")
        }
        Log.info("think-bench: done")
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
