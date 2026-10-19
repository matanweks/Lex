import Foundation

public enum IssueKind: String, Codable, CaseIterable, Sendable {
    case spelling
    case grammar
    case punctuation
    case wordChoice = "word_choice"
    case clarity

    public var label: String {
        switch self {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .punctuation: return "Punctuation"
        case .wordChoice: return "Word choice"
        case .clarity: return "Clarity"
        }
    }

    /// Correctness issues are drawn red, style issues blue.
    public var isCorrectness: Bool {
        switch self {
        case .spelling, .grammar, .punctuation: return true
        case .wordChoice, .clarity: return false
        }
    }
}

public enum IssueSource: String, Sendable {
    case local  // NSSpellChecker, instant
    case ai     // Claude, per sentence
}

/// One flagged span in the field's text. `range` is UTF-16 (NSString / AX) based.
public struct Issue: Identifiable, Equatable, Sendable {
    public let id: String
    public var range: NSRange
    public let original: String
    public let replacements: [String]
    public let kind: IssueKind
    public let message: String
    public let source: IssueSource

    public init(range: NSRange, original: String, replacements: [String], kind: IssueKind, message: String, source: IssueSource) {
        self.range = range
        self.original = original
        self.replacements = replacements
        self.kind = kind
        self.message = message
        self.source = source
        self.id = "\(source.rawValue):\(range.location):\(range.length):\(original)→\(replacements.first ?? "")"
    }
}

/// An edit as Claude returns it: a verbatim substring of the sentence and what to put instead.
public struct AIEdit: Codable, Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let kind: IssueKind
    public let reason: String

    public init(original: String, replacement: String, kind: IssueKind, reason: String) {
        self.original = original
        self.replacement = replacement
        self.kind = kind
        self.reason = reason
    }
}

public struct Sentence: Equatable, Sendable {
    public let range: NSRange
    public let text: String
    /// Ends in terminal punctuation or a line break, or the writer has moved past it.
    public let isComplete: Bool
}

extension NSRange {
    public var end: Int { location + length }

    public func intersects(_ other: NSRange) -> Bool {
        location < other.end && other.location < end
    }

    public func contains(_ other: NSRange) -> Bool {
        other.location >= location && other.end <= end
    }
}
