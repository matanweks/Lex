import Foundation

// MARK: Translation

public enum Translation {
    /// Hebrew goes to English, everything else to Hebrew: the two languages you write in.
    public static func target(for text: String) -> String {
        SpeechText.language(of: text) == "he" ? "English" : "Hebrew"
    }

    public static func action(for text: String) -> RefineAction {
        let to = target(for: text)
        return RefineAction(id: "translate", label: "To \(to)",
                            instruction: "Translate the text into \(to). Natural, idiomatic \(to), not word for word. Keep the meaning, tone, names, numbers, links and formatting.")
    }
}

// MARK: Actions on someone else's text (read-only)

extension RefineAction {
    public static let tone = RefineAction(
        id: "tone", label: "Better tone",
        instruction: "Adjust the tone so the message lands well with its reader: clear, warm and confident, never blunt, passive-aggressive or over-apologetic. Keep the content, intent and roughly the length.")

    public static let summary = RefineAction(
        id: "summary", label: "Summary",
        instruction: "Summarize this in 2 to 4 sentences: what it's about, what's being asked, and any deadline or decision. Write in the same language as the text.")

    public static let keyPoints = RefineAction(
        id: "points", label: "Key points",
        instruction: "List the key points as short bullets (at most 6). Then add a line starting \"To do:\" with anything the reader is asked to do, or \"To do: nothing\". Same language as the text.")

    public static let reply = RefineAction(
        id: "reply", label: "Draft reply",
        instruction: "Draft a reply to this message, written as its recipient: short, friendly and professional, answering every question it asks. Put facts you don't know in [brackets]. Same language as the message.")

    /// The actions offered on selected text you didn't write (an email, a thread, a page).
    public static func assist(for text: String) -> [RefineAction] {
        [summary, keyPoints, reply, Translation.action(for: text)]
    }
}

// MARK: Snippets

/// Saved text you insert by saying its name while dictating, or by typing its trigger.
public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String      // spoken: "my calendar link"
    public var trigger: String   // typed: ";cal"
    public var text: String

    public init(id: UUID = UUID(), name: String, trigger: String, text: String) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.text = text
    }
}

public enum Snippets {
    static func normalized(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// The snippet a whole dictation asks for: its name, optionally after "insert" or "paste"
    /// and "my" (so "Insert my calendar link." works too).
    public static func spokenMatch(_ transcript: String, in snippets: [Snippet]) -> Snippet? {
        var said = normalized(transcript)
        for prefix in ["insert ", "paste ", "type ", "add "] where said.hasPrefix(prefix) { said.removeFirst(prefix.count) }
        let bare = said.hasPrefix("my ") ? String(said.dropFirst(3)) : said
        return snippets.first { s in
            let name = normalized(s.name)
            guard !name.isEmpty else { return false }
            let bareName = name.hasPrefix("my ") ? String(name.dropFirst(3)) : name
            return said == name || bare == bareName
        }
    }

    /// A typed trigger just completed: the text before the caret ends with a trigger and one
    /// delimiter (space, line break or punctuation), and the trigger starts a word.
    public static func typedExpansion(in text: String, caret: Int, snippets: [Snippet]) -> (range: NSRange, snippet: Snippet)? {
        let ns = text as NSString
        guard caret >= 2, caret <= ns.length else { return nil }
        let delimiter = ns.character(at: caret - 1)
        guard let scalar = Unicode.Scalar(delimiter), " \n\t.,!?;:".unicodeScalars.contains(scalar) else { return nil }
        let before = ns.substring(to: caret - 1)
        for s in snippets {
            let trigger = s.trigger.trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty, before.hasSuffix(trigger) else { continue }
            let start = (before as NSString).length - (trigger as NSString).length
            if start > 0 {
                let previous = (before as NSString).character(at: start - 1)
                guard previous == 0x20 || previous == 0x0A || previous == 0x09 else { continue }
            }
            return (NSRange(location: start, length: (trigger as NSString).length), s)
        }
        return nil
    }
}

// MARK: Per-app styles

public enum WritingContext: String, CaseIterable, Identifiable, Sendable {
    case chat, email, documents, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .chat: return "Chat (Slack, WhatsApp, Messages…)"
        case .email: return "Email (Mail, Outlook, Superhuman…)"
        case .documents: return "Documents (Notion, Pages, Word…)"
        case .other: return "Everything else"
        }
    }

    public static let defaultStyle: [WritingContext: String] = [
        .chat: "Casual and brief, like a quick message to a colleague, with normal capitalization. No greeting or sign-off needed.",
        .email: "Professional and warm: clear paragraphs, complete sentences, a friendly greeting and sign-off when it's a full email.",
        .documents: "Clear, structured and neutral, with complete sentences.",
        .other: "",
    ]

    static let apps: [WritingContext: [String]] = [
        .chat: ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
                "com.hnc.Discord", "com.microsoft.teams2", "com.anthropic.claudefordesktop", "com.openai.chat"],
        .email: ["com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.SparkDesktop", "com.mimestream.Mimestream"],
        .documents: ["notion.id", "com.apple.iWork.Pages", "com.microsoft.Word", "md.obsidian", "net.shinyfrog.bear", "com.apple.TextEdit", "com.apple.Notes"],
    ]

    public static func of(bundleID: String) -> WritingContext {
        for (context, ids) in apps where ids.contains(bundleID) { return context }
        return .other
    }
}

// MARK: Learning words

public enum Learning {
    /// Looks like a name or term rather than a typo: capitalised, mixed case or an acronym.
    /// Lowercase words are never learned automatically.
    public static func isNameLike(_ word: String) -> Bool {
        guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) else { return false }
        return word.first?.isUppercase == true || word.dropFirst().contains(where: \.isUppercase)
    }
    /// Words the spell checker flagged that Claude, reading the whole sentence, left alone:
    /// likely names and terms, not typos.
    public static func acceptedNames(flagged: [String], edits: [AIEdit]) -> [String] {
        var seen = Set<String>()
        return flagged.filter { word in
            isNameLike(word) && seen.insert(word).inserted && !edits.contains { $0.original.contains(word) }
        }
    }
}

// MARK: Prompts

extension Prompts {
    public static let assistSystem = """
    You help the user with text they selected on screen: an email, a message thread, a page. Do exactly what the instruction asks, using only that text. Reply with just the result: no preamble, no notes, no quotes around it.
    """

    public static func assistUser(text: String, instruction: String, voice: String) -> String {
        var s = "<text>\(text)</text>\n<instruction>\(instruction)</instruction>"
        if !voice.isEmpty { s += "\n<voice>When you write as the user, sound like this: \(voice)</voice>" }
        return s
    }

    public static let toneSystem = """
    You read a message the user is about to send and tell them how it will land. Reply in at most two short lines, no preamble: first how the reader will likely read it (tone and impression), then the single biggest risk if there is one ("Risk: …"). If it reads well, say so in one line.
    """

    public static let voiceProfileSystem = """
    You describe a person's writing voice from samples of their own writing, so an assistant can write like them. In at most 70 words cover sentence length, formality, directness, how they greet and sign off, punctuation habits and favourite phrasings. Describe the style only: no quotes from the samples, no facts about their work or people they mention.
    """

    public static func voiceProfileUser(samples: [String]) -> String {
        samples.map { "<sample>\($0)</sample>" }.joined(separator: "\n")
    }
}
