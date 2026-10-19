import Foundation

public enum Prompts {
    public static let checkSystem = """
    You are the proofreading engine inside a writing assistant that checks text while the user types, one sentence at a time.

    You get the SENTENCE to check, and sometimes the text BEFORE it, for context only. Return the smallest set of edits that fix real problems in SENTENCE:
    - spelling: misspelled or mistyped words
    - grammar: agreement, tense, articles, wrong word forms, missing or extra words
    - punctuation: missing, wrong or doubled punctuation where it is clearly needed
    - word_choice: a clearly wrong or confused word (their/there, affect/effect, then/than)
    - clarity: only when a phrase is genuinely hard to follow; give a tighter phrasing

    Output one line per edit and nothing else: no heading, no repeat of the sentence. Separate the four fields with " | ":
    original | replacement | kind | reason
    kind is one of: spelling, grammar, punctuation, word_choice, clarity.
    If SENTENCE needs no edits, output exactly: OK

    How to write each edit:
    - One edit per mistake. Never return the whole sentence as a single edit.
    - "original" is copied verbatim from SENTENCE, character for character. Keep it as short as possible while it still occurs only once in SENTENCE (add a neighboring word if needed). Never quote text from BEFORE.
    - To insert something, such as a missing comma or word, include the neighboring word in both fields: original "However we" becomes replacement "However, we".
    - "replacement" replaces exactly "original". Don't repeat surrounding text that isn't in "original".
    - "reason" is at most 8 words, plain and specific.

    Leave these alone: tone and casual style (chat-style lowercase, "gonna", no final period in a chat message), names, brands, jargon, code, URLs, emails, @mentions, #channels, emoji, and anything that is a matter of taste. Keep the sentence's language and spelling variant (US or UK). When the sentence is marked unfinished, don't flag its missing ending. If nothing needs fixing, return an empty list.
    """

    public static func checkUser(sentence: String, before: String, finished: Bool) -> String {
        var s = ""
        if !before.isEmpty { s += "<before>\(before)</before>\n" }
        s += "<sentence status=\"\(finished ? "finished" : "unfinished")\">\(sentence)</sentence>"
        return s
    }

    public static let refineSystem = """
    You rewrite text inside a writing assistant. The user picked a piece of their own writing and gave an instruction. Reply with only the rewritten text: no quotes, no preamble, no explanation, no alternatives.

    Always:
    - Keep the meaning, facts, names, numbers, links, @mentions, emoji and formatting (line breaks, lists, markdown) unless the instruction says otherwise.
    - Keep the writer's voice and language. If they wrote in Hebrew, answer in Hebrew.
    - Text in <context> surrounds the piece and is there only so you understand it. Never include it in your reply.
    - If the text already satisfies the instruction, return it unchanged.
    """

    public static func refineUser(text: String, context: String, instruction: String) -> String {
        var s = ""
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty, trimmedContext != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            s += "<context>\(trimmedContext)</context>\n"
        }
        s += "<text>\(text)</text>\n<instruction>\(instruction)</instruction>"
        return s
    }
}

public struct RefineAction: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let instruction: String

    public static let improve = RefineAction(id: "improve", label: "Improve", instruction: "Fix any spelling, grammar and punctuation mistakes and smooth out awkward phrasing so it reads naturally. Keep the length and tone about the same.")
    public static let all: [RefineAction] = [
        improve,
        RefineAction(id: "fix", label: "Fix only", instruction: "Fix only spelling, grammar and punctuation mistakes. Change nothing else."),
        RefineAction(id: "shorter", label: "Shorter", instruction: "Make it noticeably shorter and tighter. Cut filler but keep every point."),
        RefineAction(id: "clearer", label: "Clearer", instruction: "Make it clearer and easier to follow. Simplify the wording and structure."),
        RefineAction(id: "friendlier", label: "Friendlier", instruction: "Make the tone warmer and friendlier while staying professional."),
        RefineAction(id: "formal", label: "Formal", instruction: "Make it more formal and polished, suitable for a client or an executive."),
        RefineAction(id: "direct", label: "Direct", instruction: "Make it more direct and confident. Lead with the point and remove hedging."),
    ]

    public static func custom(_ instruction: String) -> RefineAction {
        RefineAction(id: "custom", label: instruction, instruction: instruction)
    }
}
