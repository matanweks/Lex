import Foundation

public enum ClaudeModel: String, CaseIterable, Identifiable, Sendable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .haiku: return "Claude Haiku 5.5 (fastest)"
        case .sonnet: return "Claude Sonnet 5.5 (fast)"
        case .opus: return "Claude Opus 5.5 (best)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .haiku: return "Haiku 5.5"
        case .sonnet: return "Sonnet 5.5"
        case .opus: return "Opus 5.5"
        }
    }

    /// Every request here is latency-bound and short, so think as little as each model allows.
    public func applyLowLatency(to body: inout [String: Any], betas: inout [String]) {
        var output = body["output_config"] as? [String: Any] ?? [:]
        output["effort"] = "low"
        body["output_config"] = output
        switch self {
        case .haiku:
            body["thinking"] = ["type": "disabled"]
        case .sonnet:
            body["thinking"] = ["type": "between_tools"]
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
        case .opus:
            // Thinking can't be turned off on Opus 5.5; low effort keeps it brief.
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
        }
    }
}

public enum ClaudeError: LocalizedError, Equatable {
    case missingKey
    case http(Int, String)
    case refusal
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Anthropic API key in Settings."
        case .http(let code, let message): return "API error \(code): \(message)"
        case .refusal: return "Claude declined this request."
        case .badResponse(let why): return "Unexpected response: \(why)"
        }
    }
}

public enum SSEAction: Equatable {
    case text(String)
    /// A server-side fallback took over mid-stream; drop what came before.
    case reset
    case stop(String)
    case error(String)
    case none
}

public enum SSEParser {
    public static func parse(line: String) -> SSEAction {
        guard line.hasPrefix("data:") else { return .none }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .none }
        switch type {
        case "content_block_delta":
            if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                return .text(text)
            }
        case "content_block_start":
            if let block = obj["content_block"] as? [String: Any], block["type"] as? String == "fallback" { return .reset }
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { return .stop(reason) }
        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "stream error"
            return .error(message)
        default:
            break
        }
        return .none
    }
}

public final class ClaudeClient: @unchecked Sendable {
    private let session: URLSession
    private let apiKey: () -> String?
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private var lastRequest = Date.distantPast
    private let lock = NSLock()

    public init(apiKey: @escaping () -> String?) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    public var hasKey: Bool { !(apiKey() ?? "").isEmpty }

    /// Opens the TLS connection ahead of the first real request (costs no tokens).
    /// Skipped when a request went out recently, since the connection is still warm.
    public func warmUpIfCold() {
        lock.lock()
        let cold = Date().timeIntervalSince(lastRequest) > 45
        if cold { lastRequest = Date() }
        lock.unlock()
        guard cold, let key = apiKey(), !key.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        session.dataTask(with: req).resume()
    }

    /// Checks one sentence. Claude answers one line per edit, streamed, so each fix is
    /// handed to `onEdit` the moment its line is complete. Returns all edits at the end.
    public func check(sentence: String, before: String, finished: Bool, model: ClaudeModel, onEdit: @escaping (AIEdit) -> Void = { _ in }) async throws -> [AIEdit] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 1024,
            // Cached: the prompt is over Haiku 5.5's 512-token minimum, so repeat checks skip it.
            "system": [["type": "text", "text": Prompts.checkSystem, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": Prompts.checkUser(sentence: sentence, before: before, finished: finished)]],
        ]
        var betas: [String] = []
        model.applyLowLatency(to: &body, betas: &betas)
        var edits: [AIEdit] = []
        var buffer = ""
        func drain(final: Bool) {
            while let newline = buffer.firstIndex(of: "\n") {
                if let edit = EditLineParser.parse(String(buffer[..<newline])) { edits.append(edit); onEdit(edit) }
                buffer.removeSubrange(...newline)
            }
            if final, let edit = EditLineParser.parse(buffer) { edits.append(edit); onEdit(edit); buffer = "" }
        }
        try await stream(body: body, betas: betas) { delta in
            if let delta { buffer += delta } else { buffer = ""; edits = [] }
            drain(final: false)
        }
        drain(final: true)
        return EditLineParser.resolve(edits)
    }

    /// Streams a rewrite. `onText` gets the full text so far after every delta.
    public func refine(text: String, context: String, instruction: String, model: ClaudeModel, onText: @escaping (String) -> Void) async throws -> String {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 8000,
            "system": Prompts.refineSystem,
            "messages": [["role": "user", "content": Prompts.refineUser(text: text, context: context, instruction: instruction)]],
        ]
        var betas: [String] = []
        model.applyLowLatency(to: &body, betas: &betas)
        var full = ""
        try await stream(body: body, betas: betas) { delta in
            if let delta { full += delta } else { full = "" }
            onText(full)
        }
        return full
    }

    /// Tidies a dictation transcript (fillers, self-corrections, punctuation) without
    /// changing what was said.
    public func cleanDictation(_ transcript: String, app: String, before: String, words: [String], model: ClaudeModel) async throws -> String {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 4000,
            "system": [["type": "text", "text": Prompts.dictationSystem, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": Prompts.dictationUser(transcript: transcript, app: app, before: before, words: words)]],
        ]
        var betas: [String] = []
        model.applyLowLatency(to: &body, betas: &betas)
        var full = ""
        try await stream(body: body, betas: betas) { delta in
            if let delta { full += delta } else { full = "" }
        }
        return stripWrapper(full)
    }

    /// Strips wrapping tags or quotes a model sometimes adds.
    func stripWrapper(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["transcript", "text"] where t.hasPrefix("<\(tag)>") && t.hasSuffix("</\(tag)>") {
            t = String(t.dropFirst(tag.count + 2).dropLast(tag.count + 3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// Runs a streaming request. `onDelta` gets each text delta, or nil when a server-side
    /// fallback restarted the answer and what came before should be dropped.
    private func stream(body: [String: Any], betas: [String], onDelta: (String?) -> Void) async throws {
        var body = body
        body["stream"] = true
        let request = try makeRequest(body: body, betas: betas)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw Self.httpError(status: status, data: raw)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch SSEParser.parse(line: line) {
            case .text(let t): onDelta(t)
            case .reset: onDelta(nil)
            case .stop(let reason): if reason == "refusal" { throw ClaudeError.refusal }
            case .error(let message): throw ClaudeError.http(0, message)
            case .none: break
            }
        }
    }

    public struct Timing: Sendable {
        public let headers: Double     // response headers arrived (network + queueing)
        public let firstText: Double   // first text token
        public let total: Double
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let text: String
    }

    /// Streams any request and reports where the time went. For benchmarking.
    public func timed(body: [String: Any], betas: [String]) async throws -> Timing {
        var body = body
        body["stream"] = true
        let request = try makeRequest(body: body, betas: betas)
        let start = Date()
        let (bytes, response) = try await session.bytes(for: request)
        let headers = Date().timeIntervalSince(start)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw Self.httpError(status: status, data: raw)
        }
        var firstText: Double?
        var text = ""
        var outputTokens = 0
        var cacheRead = 0
        for try await line in bytes.lines {
            if line.contains("\"cache_read_input_tokens\""), let r = line.range(of: #""cache_read_input_tokens":(\d+)"#, options: .regularExpression) {
                cacheRead = max(cacheRead, Int(line[r].split(separator: ":").last ?? "0") ?? 0)
            }
            if case .text(let t) = SSEParser.parse(line: line) {
                if firstText == nil { firstText = Date().timeIntervalSince(start) }
                text += t
            }
            if line.hasPrefix("data:"), line.contains("\"output_tokens\""),
               let data = line.dropFirst(5).data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let usage = obj["usage"] as? [String: Any], let n = usage["output_tokens"] as? Int {
                outputTokens = n
            }
        }
        let total = Date().timeIntervalSince(start)
        return Timing(headers: headers, firstText: firstText ?? total, total: total, outputTokens: outputTokens, cacheReadTokens: cacheRead, text: text)
    }

    private func makeRequest(body: [String: Any], betas: [String]) throws -> URLRequest {
        guard let key = apiKey(), !key.isEmpty else { throw ClaudeError.missingKey }
        lock.lock(); lastRequest = Date(); lock.unlock()
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func httpError(status: Int, data: Data) -> ClaudeError {
        let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
        return .http(status, message ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? "no body")
    }
}

/// Parses Claude's check output: `original | replacement | kind | reason`, one per line.
/// Also takes tabs, or a literal "<TAB>", which models sometimes write instead.
public enum EditLineParser {
    public static func parse(_ raw: String) -> AIEdit? {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        let bare = line.trimmingCharacters(in: .whitespaces)
        guard !bare.isEmpty, bare != "OK" else { return nil }
        var fields = line.components(separatedBy: "\t")
        if fields.count < 3 { fields = line.components(separatedBy: "<TAB>") }
        if fields.count < 3 { fields = line.components(separatedBy: " | ") }
        if fields.count < 3 || fields.contains(where: { $0.contains("|") }) {
            // Doubled or unspaced pipes: split on every pipe, drop empties, and only trust the
            // result if a real kind lands in the third field.
            fields = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard fields.count >= 3, IssueKind(rawValue: fields[2].lowercased()) != nil else { return nil }
        }
        guard fields.count >= 3 else { return nil }
        let original = fields[0]
        guard !original.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let kind = IssueKind(rawValue: fields[2].trimmingCharacters(in: .whitespaces).lowercased()) ?? .grammar
        let reason = fields.count > 3 ? fields[3...].joined(separator: " ").trimmingCharacters(in: .whitespaces) : ""
        return AIEdit(original: original, replacement: isDeletionPlaceholder(fields[1]) ? "" : fields[1], kind: kind, reason: reason)
    }

    /// When the model corrects itself mid-reply ("bla | blah", later "bla |  |"), the later
    /// answer for the same words wins. Identical repeats are kept (the same typo twice).
    public static func resolve(_ edits: [AIEdit]) -> [AIEdit] {
        var out: [AIEdit] = []
        for e in edits {
            if let i = out.firstIndex(where: { $0.original == e.original && $0.replacement != e.replacement }) {
                out[i] = e
            } else {
                out.append(e)
            }
        }
        return out
    }

    /// Models sometimes write "(remove)" or "[delete]" where the replacement should be empty.
    /// Only bracketed forms count, so a real word like "remove" stays a normal suggestion.
    static func isDeletionPlaceholder(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count >= 3, let open = t.first, let close = t.last,
              ["()", "[]", "<>", "{}"].contains(String([open, close])) else { return false }
        let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return ["remove", "removed", "delete", "deleted", "none", "empty", "nothing", "omit", "omitted", "drop", "blank", "remove it", "delete it", "remove word", "delete word"].contains(inner)
    }
}
