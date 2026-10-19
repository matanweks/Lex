import Foundation
import NaturalLanguage

public enum SentenceSplitter {
    static let terminal: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "*", "_"]

    /// Splits `text` into trimmed sentences. Line breaks always end a sentence.
    /// `caret` (UTF-16 offset) decides whether an unpunctuated trailing sentence is still being typed.
    public static func split(_ text: String, caret: Int?) -> [Sentence] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var pieces: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let token = NSRange(r, in: text)
            // NLTokenizer can keep single line breaks inside a token; split them out.
            var start = token.location
            let end = token.end
            var i = start
            while i < end {
                let c = ns.character(at: i)
                if c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 {
                    if i > start { pieces.append(NSRange(location: start, length: i - start)) }
                    start = i + 1
                }
                i += 1
            }
            if end > start { pieces.append(NSRange(location: start, length: end - start)) }
            return true
        }

        var out: [Sentence] = []
        for piece in pieces {
            let r = trimmed(piece, in: ns)
            guard r.length > 0 else { continue }
            let s = ns.substring(with: r)
            out.append(Sentence(range: r, text: s, isComplete: isComplete(s, range: r, in: ns, caret: caret)))
        }
        return out
    }

    static func isComplete(_ s: String, range: NSRange, in ns: NSString, caret: Int?) -> Bool {
        if let last = s.last(where: { !closers.contains($0) }), terminal.contains(last) { return true }
        // Followed by a line break: the writer finished the line.
        var i = range.end
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x0A || c == 0x0D { return true }
            if c != 0x20 && c != 0x09 { break }
            i += 1
        }
        // The writer is somewhere else: treat it as done.
        if let caret, caret < range.location || caret > i { return true }
        return false
    }

    static func trimmed(_ r: NSRange, in ns: NSString) -> NSRange {
        var start = r.location
        var end = r.end
        while start < end, isSpace(ns.character(at: start)) { start += 1 }
        while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 || c == 0x2028 || c == 0x2029
    }
}

public enum EditMapper {
    /// Turns Claude's verbatim-substring edits into issues with ranges in the full text.
    /// Edits whose `original` can't be found are dropped rather than guessed.
    public static func issues(for edits: [AIEdit], sentence: String, base: Int) -> [Issue] {
        let ns = sentence as NSString
        var used: [NSRange] = []
        var searchFrom = 0
        var out: [Issue] = []
        for raw in edits {
            let edit = ns.range(of: raw.original).location == NSNotFound ? unquoted(raw) : raw
            guard !edit.original.isEmpty, edit.original != edit.replacement else { continue }
            var found = ns.range(of: edit.original, options: [], range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            if found.location == NSNotFound || used.contains(where: { $0.intersects(found) }) {
                found = ns.range(of: edit.original)
            }
            guard found.location != NSNotFound, !used.contains(where: { $0.intersects(found) }) else { continue }
            used.append(found)
            searchFrom = found.end

            let pieces: [(range: NSRange, original: String, replacement: String)]
            if edit.kind != .clarity {
                // One underline per mistake, even when Claude rewrote the whole sentence.
                pieces = split(original: edit.original, replacement: edit.replacement).map {
                    (NSRange(location: found.location + $0.offset, length: ($0.original as NSString).length), $0.original, $0.replacement)
                }
            } else {
                pieces = [narrow(original: edit.original, replacement: edit.replacement, at: found)]
            }
            for piece in pieces where piece.range.length > 0 {
                out.append(Issue(
                    range: NSRange(location: base + piece.range.location, length: piece.range.length),
                    original: piece.original,
                    replacements: [piece.replacement],
                    kind: edit.kind,
                    message: edit.reason,
                    source: .ai
                ))
            }
        }
        return out
    }

    /// Breaks an edit into word-level pieces. Each piece's `original` is the exact text at
    /// `offset` in the edit's original. Pure insertions (a missing comma or word) are attached
    /// to the word before them, or the word after when they come first.
    static func split(original: String, replacement: String) -> [(offset: Int, original: String, replacement: String)] {
        let o = original as NSString
        var out: [(offset: Int, original: String, replacement: String)] = []
        var offset = 0
        for chunk in WordDiff.diff(original, replacement) {
            switch chunk {
            case .same(let s):
                offset += (s as NSString).length
            case .change(let removed, let added):
                let length = (removed as NSString).length
                if removed.isEmpty {
                    if let start = wordStart(before: offset, in: o) {
                        let segment = o.substring(with: NSRange(location: start, length: offset - start))
                        out.append((start, segment, segment + added))
                    } else if let end = wordEnd(after: offset, in: o) {
                        let segment = o.substring(with: NSRange(location: offset, length: end - offset))
                        out.append((offset, segment, added + segment))
                    }
                } else {
                    out.append((offset, removed, added))
                }
                offset += length
            }
        }
        return out
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0xA0 }

    private static func wordStart(before offset: Int, in o: NSString) -> Int? {
        var i = offset - 1
        while i >= 0, isSpace(o.character(at: i)) { i -= 1 }
        guard i >= 0 else { return nil }
        while i > 0, !isSpace(o.character(at: i - 1)) { i -= 1 }
        return i
    }

    private static func wordEnd(after offset: Int, in o: NSString) -> Int? {
        var i = offset
        while i < o.length, isSpace(o.character(at: i)) { i += 1 }
        guard i < o.length else { return nil }
        while i < o.length, !isSpace(o.character(at: i)) { i += 1 }
        return i
    }

    /// Models occasionally quote the fields; strip a matching pair of quotes.
    static func unquoted(_ e: AIEdit) -> AIEdit {
        func strip(_ s: String) -> String {
            guard s.count >= 2, let f = s.first, let l = s.last,
                  (f == "\"" && l == "\"") || (f == "“" && l == "”") || (f == "'" && l == "'") else { return s }
            return String(s.dropFirst().dropLast())
        }
        return AIEdit(original: strip(e.original), replacement: strip(e.replacement), kind: e.kind, reason: e.reason)
    }

    /// Drops shared leading/trailing words so the underline sits on what actually changes:
    /// "However we" → "However, we" underlines "However".
    static func narrow(original: String, replacement: String, at range: NSRange) -> (NSRange, String, String) {
        var o = original.components(separatedBy: " ")
        var r = replacement.components(separatedBy: " ")
        var offset = 0
        while o.count > 1, r.count > 1, o[0] == r[0] {
            offset += (o[0] as NSString).length + 1
            o.removeFirst(); r.removeFirst()
        }
        while o.count > 1, r.count > 1, o[o.count - 1] == r[r.count - 1] {
            o.removeLast(); r.removeLast()
        }
        let newOriginal = o.joined(separator: " ")
        let newReplacement = r.joined(separator: " ")
        return (NSRange(location: range.location + offset, length: (newOriginal as NSString).length), newOriginal, newReplacement)
    }
}

public enum RefineScope: String, CaseIterable, Sendable {
    case sentence, paragraph, all

    public var label: String {
        switch self {
        case .sentence: return "Sentence"
        case .paragraph: return "Paragraph"
        case .all: return "All"
        }
    }
}

public enum TextTargets {
    /// What to refine: the selection if there is one, else the sentence just before the caret
    /// (the one you finished), widened to its paragraph or the whole field on request.
    public static func refineRange(in text: String, selection: NSRange, scope: RefineScope) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        if scope == .all {
            let r = SentenceSplitter.trimmed(NSRange(location: 0, length: ns.length), in: ns)
            return r.length > 0 ? r : nil
        }
        if selection.length > 0, scope == .sentence {
            return SentenceSplitter.trimmed(selection, in: ns)
        }
        // Last non-space character at or before the caret.
        var i = min(max(selection.location, 0), ns.length) - 1
        while i >= 0, SentenceSplitter.isSpace(ns.character(at: i)) { i -= 1 }
        if i < 0 {
            // Caret at the very start: fall back to the first sentence.
            return SentenceSplitter.split(text, caret: nil).first?.range
        }
        switch scope {
        case .sentence:
            let sentences = SentenceSplitter.split(text, caret: selection.location)
            return sentences.first(where: { $0.range.location <= i && i < $0.range.end })?.range
                ?? sentences.last(where: { $0.range.location <= i })?.range
        case .paragraph:
            let p = SentenceSplitter.trimmed(ns.paragraphRange(for: NSRange(location: i, length: 0)), in: ns)
            return p.length > 0 ? p : nil
        case .all:
            return nil
        }
    }

    /// The paragraph around `range`, as context for the model. Capped so requests stay fast.
    public static func context(around range: NSRange, in text: String, limit: Int = 1500) -> String {
        let ns = text as NSString
        let p = ns.paragraphRange(for: range)
        if p.length <= limit { return ns.substring(with: p) }
        let start = max(p.location, range.location - limit / 2)
        let end = min(p.end, start + limit)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// The word the caret is in or right after, so we don't flag a word mid-typing.
    public static func wordBeingTyped(in text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        func isWordChar(_ c: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(c) else { return true }  // surrogate halves: part of a word
            return CharacterSet.alphanumerics.contains(scalar) || c == 0x27 || c == 0x2019 || c == 0x2D
        }
        guard isWordChar(ns.character(at: caret - 1)) else { return nil }
        var start = caret - 1
        while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < ns.length, isWordChar(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
