import Foundation

enum Search {
    /// Score for a lowercased haystack and lowercased query, or nil if no match. Higher is better.
    static func score(_ hay: String, _ q: String, mode: SearchMode, regex: NSRegularExpression?) -> Int? {
        switch mode {
        case .exact:
            return hay.contains(q) ? 0 : nil
        case .regexp:
            return regexMatches(regex, hay) ? 0 : nil
        case .fuzzy:
            return fuzzy(hay, q, caseInsensitive: false)?.score
        case .mixed:
            if hay.contains(q) { return 3_000_000 }
            if regexMatches(regex, hay) { return 2_000_000 }
            return fuzzy(hay, q, caseInsensitive: false)?.score
        }
    }

    private static func regexMatches(_ regex: NSRegularExpression?, _ s: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Characters of `q` appear in order in `hay`. Rewards consecutive runs and word starts.
    static func fuzzy(_ hay: String, _ q: String, caseInsensitive: Bool) -> (score: Int, indices: [String.Index])? {
        guard !q.isEmpty else { return nil }
        var qi = q.startIndex
        var hi = hay.startIndex
        var score = 0
        var prevMatch: String.Index?
        var prevChar: Character = " "
        var indices: [String.Index] = []
        while hi < hay.endIndex && qi < q.endIndex {
            let c = hay[hi]
            let equal = caseInsensitive ? c.lowercased() == String(q[qi]) : c == q[qi]
            if equal {
                var s = 10
                if let p = prevMatch, hay.index(after: p) == hi { s += 15 }
                if !prevChar.isLetter && !prevChar.isNumber { s += 10 }
                score += s
                indices.append(hi)
                prevMatch = hi
                qi = q.index(after: qi)
            } else if prevMatch != nil {
                score -= 1
            }
            prevChar = c
            hi = hay.index(after: hi)
        }
        return qi == q.endIndex ? (max(score, 1), indices) : nil
    }

    /// Ranges in a display title to highlight. `q` is lowercased.
    static func ranges(in title: String, query q: String, mode: SearchMode) -> [Range<String.Index>] {
        func exact() -> [Range<String.Index>] {
            var out: [Range<String.Index>] = []
            var from = title.startIndex
            while from < title.endIndex,
                  let r = title.range(of: q, options: [.caseInsensitive], range: from..<title.endIndex) {
                out.append(r)
                from = r.upperBound
            }
            return out
        }
        func regex() -> [Range<String.Index>] {
            guard let re = try? NSRegularExpression(pattern: q, options: [.caseInsensitive]) else { return [] }
            return re.matches(in: title, range: NSRange(title.startIndex..., in: title))
                .compactMap { Range($0.range, in: title) }
                .filter { !$0.isEmpty }
        }
        func fuzzy() -> [Range<String.Index>] {
            (Search.fuzzy(title, q, caseInsensitive: true)?.indices ?? []).map { $0..<title.index(after: $0) }
        }
        switch mode {
        case .exact: return exact()
        case .regexp: return regex()
        case .fuzzy: return fuzzy()
        case .mixed:
            let e = exact(); if !e.isEmpty { return e }
            let r = regex(); if !r.isEmpty { return r }
            return fuzzy()
        }
    }
}
