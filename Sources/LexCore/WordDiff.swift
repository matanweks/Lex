import Foundation

public enum DiffChunk: Equatable, Sendable {
    case same(String)
    case change(removed: String, added: String)
}

/// Word-level diff for showing a rewrite against the original.
public enum WordDiff {
    public static func diff(_ a: String, _ b: String) -> [DiffChunk] {
        let x = tokenize(a), y = tokenize(b)
        let n = x.count, m = y.count
        // LCS table, filled from the end so we can walk forward.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var chunks: [DiffChunk] = []
        var removed = "", added = "", same = ""
        func flushChange() {
            if !removed.isEmpty || !added.isEmpty { chunks.append(.change(removed: removed, added: added)) }
            removed = ""; added = ""
        }
        func flushSame() {
            if !same.isEmpty { chunks.append(.same(same)) }
            same = ""
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] {
                flushChange(); same += x[i]; i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                flushSame(); added += y[j]; j += 1
            } else {
                flushSame(); removed += x[i]; i += 1
            }
        }
        flushChange(); flushSame()
        return coalesce(chunks)
    }

    /// Joins two changes separated only by whitespace, so "the cat" → "a dog" reads as one change.
    static func coalesce(_ chunks: [DiffChunk]) -> [DiffChunk] {
        var out: [DiffChunk] = []
        var k = 0
        while k < chunks.count {
            if case .change(var r, var a) = chunks[k] {
                while k + 2 < chunks.count,
                      case .same(let s) = chunks[k + 1],
                      s.allSatisfy({ $0 == " " }),
                      case .change(let r2, let a2) = chunks[k + 2] {
                    r += s + r2
                    a += s + a2
                    k += 2
                }
                out.append(.change(removed: r, added: a))
            } else {
                out.append(chunks[k])
            }
            k += 1
        }
        return out
    }

    /// Words (letters, digits, apostrophes), runs of whitespace, and single other characters.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsWord = false
        var currentIsSpace = false
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber || ch == "'" || ch == "’"
            let isSpace = ch.isWhitespace
            if isWord, currentIsWord || current.isEmpty {
                current.append(ch); currentIsWord = true; currentIsSpace = false
            } else if isSpace, currentIsSpace || current.isEmpty {
                current.append(ch); currentIsSpace = true; currentIsWord = false
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(ch)
                currentIsWord = isWord
                currentIsSpace = isSpace
                if !isWord, !isSpace {
                    tokens.append(current); current = ""
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
