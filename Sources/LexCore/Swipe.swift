import Foundation

/// Swipe typing: the words a finger's path across the letter keys most likely spells. Each
/// candidate word's keys are joined into a line, and the path is compared with it: how close
/// the path comes to each key, in order, and how close it stays to the line. The likeliest
/// words win: close to the path, common, yours, and fitting the words before.
public enum SwipeTyping {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// How much each part of the comparison counts, tuned on simulated swipes over common
    /// words, tidy and sloppy (about 96% come out first, all but a few in the top three).
    struct Weights {
        /// The typical distance, in key widths, from the path to a key it meant.
        var near = 0.3
        /// The typical distance from the path to the word's line.
        var shape = 0.5
        /// The typical difference between the path's length and the line's, as a share of it.
        var length = 0.3
        /// How much a common word counts (times the log of its count).
        var common = 0.35
        /// The typical distance from where the path starts and ends to the word's first and
        /// last keys: a swipe starts and ends on them more surely than it passes the others.
        var ends = 0.5
    }

    /// Points the path and each word's line are resampled to, evenly along them.
    static let samples = 40
    /// A path shorter than this many key widths is a tap that slid, not a swipe.
    public static let shortest = 0.6

    /// Best first, as the word lists write them (lowercase). `keys` are the letter keys'
    /// centres, and `keyWidth` the distance from one key's centre to the next, in the path's
    /// units. `previous` and `earlier` are the two words before. Empty when nothing fits.
    public static func words(path: [Point], keys: [Character: Point], keyWidth: Double, lexicon: Lexicon,
                             model: WordModel = WordModel(), names: [String: String] = [:],
                             previous: String? = nil, earlier: String? = nil, limit: Int = 4) -> [String] {
        words(path: path, keys: keys, keyWidth: keyWidth, lexicon: lexicon, model: model, names: names,
              previous: previous, earlier: earlier, limit: limit, weights: Weights())
    }

    static func words(path: [Point], keys: [Character: Point], keyWidth: Double, lexicon: Lexicon, model: WordModel,
                      names: [String: String], previous: String?, earlier: String?, limit: Int, weights w: Weights) -> [String] {
        guard path.count >= 2, keyWidth > 0, !keys.isEmpty else { return [] }
        let scale = 1 / keyWidth
        let scaled = path.map { Point(x: $0.x * scale, y: $0.y * scale) }
        let traced = length(scaled)
        guard traced >= shortest else { return [] }
        let trace = resample(scaled, samples)
        let centres = keys.mapValues { Point(x: $0.x * scale, y: $0.y * scale) }
        let starts = near(trace[0], centres)
        let ends = near(trace[trace.count - 1], centres)

        // Words that start and end near where the finger did.
        struct Candidate { var common = 0, yours = 0, name = false }
        var candidates: [String: Candidate] = [:]
        func fits(_ word: String) -> Bool {
            guard let first = word.first, starts.contains(first), let last = lastKey(word, centres) else { return false }
            return ends.contains(last)
        }
        for letter in starts {
            for (word, count) in lexicon.words(startingWith: String(letter)) where fits(word) {
                candidates[word, default: Candidate()].common = count
            }
        }
        for (word, count) in model.words where fits(word) && (count >= 2 || candidates[word] != nil) {
            candidates[word, default: Candidate()].yours = count
        }
        for lower in names.keys where fits(lower) { candidates[lower, default: Candidate()].name = true }
        guard !candidates.isEmpty else { return [] }

        let p = previous?.lowercased()
        let afterTwo = p.flatMap { p in earlier.map { $0.lowercased() + " " + p } }
        func ranks(_ list: [String]?) -> [String: Int] {
            Dictionary((list ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        }
        let nextTwo = ranks(afterTwo.flatMap { lexicon.next[$0] })
        let nextOne = ranks(p.flatMap { lexicon.next[$0] })

        var scored: [(word: String, score: Double)] = []
        scored.reserveCapacity(candidates.count)
        for (word, candidate) in candidates {
            guard let line = keyLine(word, centres) else { continue }
            let ideal = length(line)
            // Far too long or too short a line for the path.
            guard ideal <= traced * 1.7 + 1.5, ideal >= traced * 0.4 - 1.5 else { continue }
            let near = alignment(line, trace)
            guard near < 1.2 else { continue }
            let shape = zip(resample(line, samples), trace).reduce(0) { $0 + distance($1.0, $1.1) } / Double(samples)
            let stretch = (traced - ideal) / (traced + 1)
            let start = distance(line[0], trace[0]), end = distance(line[line.count - 1], trace[trace.count - 1])
            var score = -(pow(near / w.near, 2) + pow(shape / w.shape, 2) + pow(stretch / w.length, 2)) / 2
            score -= (pow(start / w.ends, 2) + pow(end / w.ends, 2)) / 2
            score += w.common * log(1 + Double(candidate.common))
            score += 0.9 * log(1 + Double(candidate.yours))
            if candidate.name { score += 3 }
            if let i = nextTwo[word] { score += 2.5 - 0.25 * Double(i) }
            if let i = nextOne[word] { score += 1.4 - 0.1 * Double(i) }
            if let p {
                score += 1.2 * log(1 + Double(model.count(word, after: p)))
                if let e = earlier { score += 1.5 * log(1 + Double(model.count(word, after: p, earlier: e))) }
            }
            scored.append((word, score))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }.prefix(limit).map(\.word)
    }

    // MARK: Geometry

    /// The letters whose keys are near `point`, nearest first: the key under it and its
    /// neighbours when it's between keys.
    static func near(_ point: Point, _ centres: [Character: Point]) -> [Character] {
        let sorted = centres.map { ($0.key, distance($0.value, point)) }.sorted { $0.1 < $1.1 }
        guard let nearest = sorted.first else { return [] }
        return sorted.filter { $0.1 <= max(1.15, nearest.1 + 0.3) }.map(\.0)
    }

    /// The last letter of `word` that's on a key (not an apostrophe or hyphen), or nil when it
    /// has a letter that isn't on the keyboard.
    static func lastKey(_ word: String, _ centres: [Character: Point]) -> Character? {
        for ch in word.reversed() where !skipped.contains(ch) {
            return centres[ch] == nil ? nil : ch
        }
        return nil
    }

    static let skipped: Set<Character> = ["'", "’", "-"]

    /// The centres of the word's keys, in order, a doubled letter once ("hello" → h e l o).
    /// Nil when a letter isn't on the keyboard.
    static func keyLine(_ word: String, _ centres: [Character: Point]) -> [Point]? {
        var line: [Point] = []
        var last: Character?
        for ch in word where !skipped.contains(ch) {
            guard let centre = centres[ch] else { return nil }
            if ch != last { line.append(centre) }
            last = ch
        }
        return line.isEmpty ? nil : line
    }

    /// How near the path comes to the word's keys: the mean distance from each key to the
    /// path, the keys met in order along it, the first where it starts and the last where it
    /// ends.
    static func alignment(_ keys: [Point], _ trace: [Point]) -> Double {
        let n = trace.count, k = keys.count
        guard n > 0, k > 0 else { return .infinity }
        if k == 1 { return (distance(keys[0], trace[0]) + distance(keys[0], trace[n - 1])) / 2 }
        var best = [Double](repeating: .infinity, count: n)
        best[0] = distance(keys[0], trace[0])
        for i in 1..<k {
            var next = [Double](repeating: .infinity, count: n)
            var running = Double.infinity
            let lastKey = i == k - 1
            for t in 0..<n {
                running = min(running, best[t])
                if lastKey, t != n - 1 { continue }
                next[t] = running + distance(keys[i], trace[t])
            }
            best = next
        }
        return best[n - 1] / Double(k)
    }

    static func distance(_ a: Point, _ b: Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    static func length(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// `count` points evenly spaced along the line through `points`.
    static func resample(_ points: [Point], _ count: Int) -> [Point] {
        guard let first = points.first else { return [] }
        let total = length(points)
        guard total > 0, count > 1 else { return Array(repeating: first, count: count) }
        let step = total / Double(count - 1)
        var out = [first]
        out.reserveCapacity(count)
        var carried = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = distance(a, b)
            guard segment > 0 else { continue }
            var along = step - carried
            while along <= segment, out.count < count {
                let f = along / segment
                out.append(Point(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                along += step
            }
            carried = segment - (along - step)
        }
        while out.count < count { out.append(points[points.count - 1]) }
        return out
    }
}

extension Lexicon {
    /// The words that start with `prefix`, the prefix itself included, with their counts.
    public func words(startingWith prefix: String) -> [(word: String, count: Int)] {
        let p = prefix.lowercased()
        return (count(p) > 0 ? [(p, count(p))] : []) + completions(p, limit: .max)
    }
}
