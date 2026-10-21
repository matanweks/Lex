import Foundation

/// Every emoji, in the order keyboards show them, with English and Hebrew words to find them
/// by (made by scripts/make-emoji.py from Unicode's emoji list and CLDR's names).
public struct EmojiCatalog: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let emoji: String
        public let group: Int
        public let name: String
        /// Lowercased search words: the English name and keywords, then the Hebrew ones.
        let words: [String]
        /// The skin tones, offered on a long press.
        public let tones: [String]
        public var id: String { emoji }
    }

    public let groups: [String]
    public let entries: [Entry]

    public static let empty = EmojiCatalog(groups: [], entries: [])

    init(groups: [String], entries: [Entry]) {
        self.groups = groups
        self.entries = entries
    }

    /// From the file: "#group<TAB>name" lines, then "emoji<TAB>name<TAB>keywords<TAB>Hebrew<TAB>tones" lines.
    public init(file: String) {
        var groups: [String] = []
        var entries: [Entry] = []
        for line in file.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "#group", fields.count > 1 {
                groups.append(fields[1])
                continue
            }
            guard !line.hasPrefix("#"), fields.count >= 4, !groups.isEmpty else { continue }
            let words = (fields[1] + " " + fields[2] + " " + fields[3]).lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "|" || $0 == ":" || $0 == "," }).map(String.init)
            let tones = fields.count > 4 ? fields[4].split(separator: " ").map(String.init) : []
            entries.append(Entry(emoji: fields[0], group: groups.count - 1, name: fields[1], words: words, tones: tones))
        }
        self.init(groups: groups, entries: entries)
    }

    public func entries(in group: Int) -> [Entry] { entries.filter { $0.group == group } }

    /// Emoji whose words start with every word of `query` (English or Hebrew), best matches
    /// first: a name that starts with the query, then a word of the name, then a keyword.
    public func search(_ query: String, limit: Int = 60) -> [Entry] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var scored: [(Entry, Int, Int)] = []
        for (i, entry) in entries.enumerated() {
            guard terms.allSatisfy({ term in entry.words.contains { $0.hasPrefix(term) } }) else { continue }
            let nameWords = entry.name.lowercased().split(separator: " ")
            let score: Int
            if entry.name.lowercased().hasPrefix(query.lowercased()) || entry.words.first == terms[0] {
                score = 3
            } else if nameWords.contains(where: { $0.hasPrefix(terms[0]) }) {
                score = 2
            } else {
                score = 1
            }
            scored.append((entry, score, i))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.prefix(limit).map(\.0)
    }
}
