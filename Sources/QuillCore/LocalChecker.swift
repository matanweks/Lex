import AppKit

/// macOS's own spelling and grammar checker. Runs in a few milliseconds, offline,
/// so underlines show up while you type, before Claude has seen the sentence.
public final class LocalChecker: @unchecked Sendable {
    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()

    public init() {}

    /// Checks `text` off the main thread and calls back on the main thread.
    public func check(_ text: String, completion: @escaping ([Issue]) -> Void) {
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        let full = NSRange(location: 0, length: (text as NSString).length)
        checker.requestChecking(of: text, range: full, types: types, options: nil, inSpellDocumentWithTag: tag) { [weak self] _, results, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                completion(self.issues(from: results, in: text))
            }
        }
    }

    /// Synchronous variant, for tests.
    public func checkNow(_ text: String) -> [Issue] {
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        let full = NSRange(location: 0, length: (text as NSString).length)
        let results = checker.check(text, range: full, types: types, options: nil, inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil)
        return issues(from: results, in: text)
    }

    public func learn(_ word: String) {
        checker.learnWord(word)
    }

    func issues(from results: [NSTextCheckingResult], in text: String) -> [Issue] {
        let ns = text as NSString
        var out: [Issue] = []
        for r in results {
            guard r.range.end <= ns.length else { continue }
            if r.resultType == .spelling {
                let word = ns.substring(with: r.range)
                var guesses: [String] = []
                if let best = checker.correction(forWordRange: r.range, in: text, language: checker.language(), inSpellDocumentWithTag: tag) {
                    guesses.append(best)
                }
                for g in checker.guesses(forWordRange: r.range, in: text, language: nil, inSpellDocumentWithTag: tag) ?? [] where !guesses.contains(g) {
                    guesses.append(g)
                }
                out.append(Issue(range: r.range, original: word, replacements: Array(guesses.prefix(3)), kind: .spelling, message: "Possible spelling mistake", source: .local))
            } else if r.resultType == .grammar {
                for detail in r.grammarDetails ?? [] {
                    guard let value = detail[NSGrammarRange] as? NSValue else { continue }
                    let rel = value.rangeValue
                    // Grammar detail ranges are relative to the flagged sentence.
                    let abs = NSRange(location: r.range.location + rel.location, length: rel.length)
                    guard abs.length > 0, abs.end <= ns.length else { continue }
                    let corrections = detail[NSGrammarCorrections] as? [String] ?? []
                    let message = detail[NSGrammarUserDescription] as? String ?? "Possible grammar issue"
                    out.append(Issue(range: abs, original: ns.substring(with: abs), replacements: Array(corrections.prefix(3)), kind: .grammar, message: message, source: .local))
                }
            }
        }
        return out
    }
}

/// Claude's verdict on one sentence. `text` is the sentence as it was when checked;
/// `complete` is false while the answer is still streaming in.
public struct AIReview: Sendable {
    public let text: String
    public let edits: [AIEdit]
    public let complete: Bool

    public init(text: String, edits: [AIEdit], complete: Bool) {
        self.text = text
        self.edits = edits
        self.complete = complete
    }
}

public enum IssueComposer {
    /// Merges instant local findings with Claude's per-sentence findings.
    /// - A finished review of the exact sentence is authoritative: local flags inside it are
    ///   dropped (that's how names and jargon stop being flagged).
    /// - A review of an older version of the sentence (you're editing it) keeps its fixes
    ///   that still apply, so underlines don't flicker while the re-check runs. Local flags
    ///   stay hidden for words Claude already saw, and show for words you just typed.
    public static func compose(text: String, caret: Int?, local: [Issue], review: (Sentence) -> AIReview?, ignored: Set<String>) -> [Issue] {
        let sentences = SentenceSplitter.split(text, caret: caret)
        var aiIssues: [Issue] = []
        var reviewed: [NSRange] = []
        var staleWords: [(NSRange, Set<String>)] = []
        for s in sentences {
            guard let r = review(s) else { continue }
            aiIssues += EditMapper.issues(for: r.edits, sentence: s.text, base: s.range.location)
            if r.text == s.text {
                if r.complete { reviewed.append(s.range) }
            } else {
                staleWords.append((s.range, words(in: r.text)))
            }
        }
        let typing = caret.flatMap { TextTargets.wordBeingTyped(in: text, caret: $0) }
        let length = (text as NSString).length
        let localKept = local.filter { issue in
            guard issue.range.end <= length,
                  !reviewed.contains(where: { $0.intersects(issue.range) }),
                  !aiIssues.contains(where: { $0.range.intersects(issue.range) }),
                  !(typing.map { $0.intersects(issue.range) } ?? false) else { return false }
            if let (_, seen) = staleWords.first(where: { $0.0.intersects(issue.range) }), seen.contains(issue.original) {
                return false
            }
            return true
        }
        return (aiIssues + localKept)
            .filter { !ignored.contains(ignoreKey($0)) }
            .sorted { $0.range.location < $1.range.location }
    }

    static func words(in s: String) -> Set<String> {
        Set(s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-")).inverted).filter { !$0.isEmpty })
    }

    public static func ignoreKey(_ issue: Issue) -> String {
        "\(issue.original)→\(issue.replacements.first ?? "")"
    }

    /// Keeps issues pinned to their text while the user types elsewhere:
    /// shifts ranges after the edit, drops the ones the edit touched.
    public static func shift(_ issues: [Issue], from old: String, to new: String) -> [Issue] {
        let a = old as NSString, b = new as NSString
        var prefix = 0
        let maxPrefix = min(a.length, b.length)
        while prefix < maxPrefix, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < maxPrefix - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        let oldEditEnd = a.length - suffix
        let delta = b.length - a.length
        return issues.compactMap { issue in
            if issue.range.end <= prefix { return issue }
            if issue.range.location >= oldEditEnd {
                var moved = issue
                moved.range.location += delta
                return moved
            }
            return nil
        }
    }
}
