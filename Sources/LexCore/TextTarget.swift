import Foundation

/// The text a keyboard action works on, split from the spaces and line breaks around it, so
/// a rewrite goes back with the same spacing.
public struct TextTarget: Equatable, Sendable {
    /// Exactly as it is in the field.
    public let original: String
    public let lead: String
    public let core: String
    public let tail: String

    /// Nil when there's nothing but spaces.
    public init?(_ original: String) {
        let lead = String(original.prefix(while: \.isWhitespace))
        let rest = original.dropFirst(lead.count)
        let tail = String(rest.reversed().prefix(while: \.isWhitespace).reversed())
        let core = String(rest.dropLast(tail.count))
        guard !core.isEmpty else { return nil }
        self.original = original
        self.lead = lead
        self.core = core
        self.tail = tail
    }

    /// What you just wrote: the paragraph up to the cursor. Right after a line break, that's
    /// the paragraph above (the break stays in `tail`).
    public static func beforeCursor(_ before: String) -> TextTarget? {
        guard let last = before.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        let start = before[..<last].lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        return TextTarget(String(before[start...]))
    }

    /// The text to type in place of `original`.
    public func replacement(_ new: String) -> String {
        lead + new.trimmingCharacters(in: .whitespacesAndNewlines) + tail
    }

    public var words: Int { core.split(whereSeparator: \.isWhitespace).count }
}
