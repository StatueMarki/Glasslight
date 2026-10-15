import Foundation

/// A string pre-normalized once at index time so matching per keystroke is cheap.
/// "Visual Studio Code" -> chars "visualstudiocode", wordStarts [0, 6, 12], initials "vsc".
struct SearchKey {
    let raw: String
    let chars: [UInt32]
    let wordStarts: [Int]
    let initials: [UInt32]

    init(_ raw: String) {
        self.raw = raw
        var chars: [UInt32] = []
        var starts: [Int] = []
        var initials: [UInt32] = []
        enum Kind { case separator, lower, upper, digit }
        var prev = Kind.separator

        for ch in raw {
            guard ch.isLetter || ch.isNumber else { prev = .separator; continue }
            let kind: Kind = ch.isNumber ? .digit : (ch.isUppercase ? .upper : .lower)
            // Word boundaries: after separators, camelCase humps ("FaceTime"), letter<->digit.
            let boundary = prev == .separator
                || (kind == .upper && prev == .lower)
                || ((kind == .digit) != (prev == .digit))
            let folded = String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            let scalars = folded.unicodeScalars.map(\.value)
            if boundary, let first = scalars.first {
                starts.append(chars.count)
                initials.append(first)
            }
            chars.append(contentsOf: scalars)
            prev = kind
        }
        self.chars = chars
        self.wordStarts = starts.isEmpty ? [0] : starts
        self.initials = initials
    }
}

enum Matcher {
    /// Scores how well query `q` (already normalized) matches `key`. 0 = no match.
    /// Tiers: exact 1000+ > prefix 900+ > word prefix 800+ > initials 780+ > substring 650+
    ///        > typo-tolerant prefix 210-520 > scattered subsequence 150-300.
    static func score(_ q: [UInt32], _ key: SearchKey) -> Double {
        let c = key.chars
        let m = q.count, n = c.count
        guard m > 0, n > 0 else { return 0 }
        let coverage = 50 * Double(min(m, n)) / Double(n) // prefer names the query covers more of

        if hasPrefix(c, q, at: 0) { return (m == n ? 1000 : 900) + coverage }
        for s in key.wordStarts.dropFirst() where hasPrefix(c, q, at: s) { return 800 + coverage }
        if m >= 2, hasPrefix(key.initials, q, at: 0) { return 780 + (m == key.initials.count ? 20 : 0) }
        if m >= 2, contains(c, q) { return 650 + coverage }

        if m >= 3 {
            let limit = m <= 4 ? 1 : (m <= 7 ? 2 : 3)
            var best = limit + 1
            for s in key.wordStarts {
                // Short queries must get the first letter right (or swap the first two) to keep noise out;
                // longer ones carry enough signal to also catch "fotoshop".
                guard m >= 5 || c[s] == q[0] || (s + 1 < n && c[s] == q[1] && c[s + 1] == q[0]) else { continue }
                best = min(best, prefixDistance(q, c, from: s, limit: limit))
                if best == 1 { break }
            }
            if best <= limit { return 600 - 130 * Double(best) + coverage }
        }

        if m >= 2, let span = tightestSpan(q, c) { return 150 + 150 * Double(m) / Double(span) }
        return 0
    }

    @inline(__always)
    static func hasPrefix(_ c: [UInt32], _ q: [UInt32], at s: Int) -> Bool {
        guard s + q.count <= c.count else { return false }
        for i in 0..<q.count where c[s + i] != q[i] { return false }
        return true
    }

    static func contains(_ c: [UInt32], _ q: [UInt32]) -> Bool {
        guard q.count <= c.count else { return false }
        for s in 0...(c.count - q.count) where hasPrefix(c, q, at: s) { return true }
        return false
    }

    /// Damerau (OSA) edit distance between `q` and the best-matching prefix of `c[from...]`.
    /// Handles missing, extra, wrong and swapped letters: "blendr", "photshop", "safri", "bledner".
    static func prefixDistance(_ q: [UInt32], _ c: [UInt32], from s: Int, limit: Int) -> Int {
        let m = q.count
        let n = min(c.count - s, m + limit)
        guard n > 0 else { return m }
        var prev2 = [Int](repeating: 0, count: n + 1)
        var prev = Array(0...n)
        var cur = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            cur[0] = i
            var rowMin = i
            for j in 1...n {
                let cost = q[i - 1] == c[s + j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, q[i - 1] == c[s + j - 2], q[i - 2] == c[s + j - 1] {
                    v = min(v, prev2[j - 2] + 1)
                }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev.min()!
    }

    /// Length of the shortest window of `c` containing `q` as an in-order subsequence.
    static func tightestSpan(_ q: [UInt32], _ c: [UInt32]) -> Int? {
        var best: Int?
        for start in c.indices where c[start] == q[0] {
            var qi = 1, ci = start + 1
            while qi < q.count, ci < c.count {
                if c[ci] == q[qi] { qi += 1 }
                ci += 1
            }
            guard qi == q.count else { break } // later starts can't succeed either
            let span = ci - start
            if best == nil || span < best! { best = span }
        }
        return best
    }
}

/// An installed application, indexed for search.
final class AppEntry: Sendable {
    let url: URL
    let name: String
    /// Stable identity for learning (bundle id, falling back to path).
    let id: String
    /// Display name first, then aliases such as the on-disk file name.
    let keys: [SearchKey]

    init(url: URL, name: String, id: String, aliases: [String] = []) {
        self.url = url
        self.name = name
        self.id = id
        var seen = Set<String>()
        self.keys = ([name] + aliases).filter { seen.insert($0.lowercased()).inserted }.map(SearchKey.init)
    }
}

enum Ranker {
    static func normalize(_ query: String) -> [UInt32] { SearchKey(query).chars }

    static func search(_ query: String, in apps: [AppEntry], usage: Usage, limit: Int,
                       now: Double = Date().timeIntervalSince1970) -> [AppEntry] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let queryKey = Usage.key(q)
        var scored: [(score: Double, app: AppEntry)] = []
        scored.reserveCapacity(32)
        for app in apps {
            var best = 0.0
            for (i, key) in app.keys.enumerated() {
                best = max(best, Matcher.score(q, key) - (i == 0 ? 0 : 5))
            }
            guard best > 0 else { continue }
            scored.append((best + usage.boost(query: queryKey, id: app.id, now: now), app))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
        }
        return scored.prefix(limit).map(\.app)
    }
}
