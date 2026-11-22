import Foundation

/// A language's word list: how common each word is, and the words that usually follow each
/// one. The keyboard ships one for English and one for Hebrew (made by scripts/make-words.py
/// from open word lists).
public struct Lexicon: Sendable {
    /// Lowercased and sorted, for finding the words that start with what you typed.
    private let sorted: [String]
    private let sortedCounts: [Int]
    private let counts: [String: Int]
    /// Word ("" for the start of a sentence), or two words ("like to"), → the words that most
    /// often follow, likeliest first.
    public let next: NextWords
    /// The most common word's count, to compare the others with.
    public let topCount: Int

    public static let empty = Lexicon(words: [], next: [:])

    public init(words: [(String, Int)], next: [String: [String]]) {
        self.init(words: words, next: NextWords(next))
    }

    public init(words: [(String, Int)], next: NextWords) {
        var counts: [String: Int] = [:]
        for (word, count) in words { counts[word.lowercased(), default: 0] += count }
        let sorted = counts.keys.sorted()
        self.sorted = sorted
        self.sortedCounts = sorted.map { counts[$0] ?? 0 }
        self.counts = counts
        self.next = next
        self.topCount = max(counts.values.max() ?? 1, 1)
    }

    /// From the files: "word<TAB>count" lines, and "word<TAB>next next …" lines in any order.
    public init(wordsFile: String, nextFile: String) {
        self.init(wordsFile: wordsFile, next: NextWords(file: nextFile))
    }

    /// The keyboard's files: the next words' file is sorted (scripts/make-words.py) and read
    /// as it's needed, not all at once.
    public init(wordsFile: String, sortedNextFile: Data) {
        self.init(wordsFile: wordsFile, next: NextWords(sortedFile: sortedNextFile))
    }

    private init(wordsFile: String, next: NextWords) {
        var words: [(String, Int)] = []
        words.reserveCapacity(50_000)
        for line in wordsFile.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let count = Int(line[line.index(after: tab)...]) else { continue }
            words.append((String(line[..<tab]), count))
        }
        self.init(words: words, next: next)
    }

    public var isEmpty: Bool { counts.isEmpty }

    public func count(_ word: String) -> Int { counts[word.lowercased()] ?? 0 }

    public func contains(_ word: String) -> Bool { counts[word.lowercased()] != nil }

    /// How common the word is, from 0 (not in the list) to 1 (the most common word), on a log scale.
    public func commonness(_ word: String) -> Double {
        let n = count(word)
        return n > 0 ? log(1 + Double(n)) / log(1 + Double(topCount)) : 0
    }

    /// The commonest words that start with `prefix` (not the prefix itself), commonest first.
    /// A Hebrew letter typed last may be the word's final form ("שלומ" finds "שלום").
    public func completions(_ prefix: String, limit: Int = 8) -> [(word: String, count: Int)] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        var found = startingWith(p)
        if let last = p.last, let final = TypingRules.finalForms[last] {
            let ending = String(p.dropLast()) + String(final)
            found += startingWith(ending) + (counts[ending].map { [(ending, $0)] } ?? [])
        }
        return Array(found.sorted { $0.count > $1.count }.prefix(limit))
    }

    private func startingWith(_ p: String) -> [(word: String, count: Int)] {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < p { low = mid + 1 } else { high = mid }
        }
        var found: [(word: String, count: Int)] = []
        var i = low
        while i < sorted.count, sorted[i].hasPrefix(p) {
            if sorted[i] != p { found.append((sorted[i], sortedCounts[i])) }
            i += 1
        }
        return found
    }
}

/// The words that usually follow a word or two, looked up in the word list's "key<TAB>next
/// next …" lines. The lines are sorted by the key's UTF-8 bytes and searched where they lie,
/// so a big file costs the keyboard little memory (iOS stops keyboards that use much).
public struct NextWords: Sendable {
    private let table: Data

    /// Lines sorted by key, as scripts/make-words.py writes them. The data can be mapped from
    /// the file.
    public init(sortedFile: Data) {
        table = sortedFile
    }

    /// Lines in any order.
    public init(file: String) {
        let lines = file.split(separator: "\n", omittingEmptySubsequences: true).filter { $0.contains("\t") }
        self.init(lines.map { line in
            let tab = line.firstIndex(of: "\t")!
            return (String(line[..<tab]), line[line.index(after: tab)...].split(separator: " ").map(String.init))
        })
    }

    public init(_ next: [String: [String]]) {
        self.init(next.map { ($0.key, $0.value) })
    }

    private init(_ entries: [(String, [String])]) {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.0).inserted }
        let sorted = unique.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        table = Data(sorted.map { "\($0.0)\t\($0.1.joined(separator: " "))\n" }.joined().utf8)
    }

    public var isEmpty: Bool { table.isEmpty }

    private static let tab = UInt8(ascii: "\t"), newline = UInt8(ascii: "\n"), space = UInt8(ascii: " ")

    /// The words after `key` ("" for a sentence's first words), likeliest first.
    public subscript(key: String) -> [String]? {
        let wanted = Array(key.utf8)
        return table.withUnsafeBytes { raw -> [String]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var low = 0, high = bytes.count
            while low < high {
                var start = (low + high) / 2
                while start > low, bytes[start - 1] != Self.newline { start -= 1 }
                var end = start
                while end < bytes.count, bytes[end] != Self.tab, bytes[end] != Self.newline { end += 1 }
                let order = Self.compare(bytes, start..<end, wanted)
                if order == 0 {
                    guard end < bytes.count, bytes[end] == Self.tab else { return [] }
                    var stop = end + 1
                    while stop < bytes.count, bytes[stop] != Self.newline { stop += 1 }
                    return UnsafeBufferPointer(rebasing: bytes[(end + 1)..<stop]).split(separator: Self.space).map { String(decoding: $0, as: UTF8.self) }
                }
                if order < 0 {
                    while end < bytes.count, bytes[end] != Self.newline { end += 1 }
                    low = end + 1
                } else {
                    high = start
                }
            }
            return nil
        }
    }

    private static func compare(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ wanted: [UInt8]) -> Int {
        var i = range.lowerBound, j = 0
        while i < range.upperBound, j < wanted.count {
            if bytes[i] != wanted[j] { return bytes[i] < wanted[j] ? -1 : 1 }
            i += 1
            j += 1
        }
        if i == range.upperBound { return j == wanted.count ? 0 : -1 }
        return 1
    }
}

// MARK: Hebrew autocorrect

extension TypingRules {
    /// Hebrew letters that take a different form at the end of a word.
    static let finalForms: [Character: Character] = ["כ": "ך", "מ": "ם", "נ": "ן", "פ": "ף", "צ": "ץ"]
    public static let hebrewLetters = Set("אבגדהוזחטיכלמנסעפצקרשתךםןףץ")

    /// The fix to make when a space ends a Hebrew `word`, or nil. Careful, since Hebrew words
    /// take many forms a word list doesn't have: only a word the list doesn't know, made into a
    /// common one by its end letter's final form ("שלומ" → "שלום"), or by one slip of a finger
    /// to a neighbouring key or two swapped letters.
    public static func hebrewCorrection(for word: String, lexicon: Lexicon) -> String? {
        let letters = Array(word)
        guard letters.count >= 2, letters.allSatisfy({ hebrewLetters.contains($0) }), !lexicon.contains(word) else { return nil }
        if let last = letters.last, let final = finalForms[last] {
            let fixed = String(letters.dropLast()) + String(final)
            if lexicon.contains(fixed) { return fixed }
        }
        guard letters.count >= 3 else { return nil }
        let neighbors = KeyboardLayout.neighbors(.hebrew)
        var candidates: [String] = []
        for i in letters.indices {
            for other in neighbors[letters[i]] ?? [] {
                var changed = letters
                changed[i] = other
                candidates.append(String(changed))
            }
            if i + 1 < letters.count, letters[i] != letters[i + 1] {
                var swapped = letters
                swapped.swapAt(i, i + 1)
                candidates.append(String(swapped))
            }
        }
        // Common words only, and clearly the likeliest.
        let found = candidates.map { ($0, lexicon.count($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard let best = found.first, lexicon.commonness(best.0) >= 0.45 else { return nil }
        if found.count > 1, found[1].1 * 3 > best.1 { return nil }
        return best.0
    }
}

extension KeyboardLayout {
    /// The letter keys around each letter key: the ones beside it, and the ones above and
    /// below that touch it.
    public static func neighbors(_ language: KeyboardLanguage) -> [Character: [Character]] {
        var keys: [(Character, x: Double, row: Int)] = []
        for (r, row) in rows(.letters, language).prefix(3).enumerated() {
            let width = row.reduce(0) { $0 + $1.width }
            var x = (unitsPerRow - width) / 2
            for cap in row {
                if case .character(let c) = cap.action, let letter = c.first, letter.isLetter { keys.append((letter, x + cap.width / 2, r)) }
                x += cap.width
            }
        }
        var out: [Character: [Character]] = [:]
        for key in keys {
            out[key.0] = keys.filter { other in
                other.0 != key.0 && ((other.row == key.row && abs(other.x - key.x) <= 1.01) || (abs(other.row - key.row) == 1 && abs(other.x - key.x) <= 0.75))
            }.map(\.0)
        }
        return out
    }
}

// MARK: Sentence completion

/// Claude's guess at the rest of a sentence, made fit for the suggestion bar.
public enum SentenceCompletion {
    /// The first line, without quotes or a repeat of the last words typed; "" when it's
    /// empty, too long, or not really a continuation.
    public static func clean(_ raw: String, before: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(text.prefix { !$0.isNewline })
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        text = text.trimmingCharacters(in: .whitespaces)
        // Some answers start over with the words just typed.
        let typed = before.split(separator: " ").suffix(4).map(String.init)
        for n in stride(from: typed.count, to: 0, by: -1) {
            let tail = typed.suffix(n).joined(separator: " ")
            if text.lowercased().hasPrefix(tail.lowercased() + " ") {
                text = String(text.dropFirst(tail.count + 1))
                break
            }
        }
        let lowered = text.lowercased()
        guard !text.isEmpty, text.count <= 70, text.split(separator: " ").count <= 10,
              !["nothing", "none", "(nothing)", "n/a", "ok"].contains(lowered.trimmingCharacters(in: .punctuationCharacters)),
              !text.hasPrefix("<") else { return "" }
        return text
    }
}
