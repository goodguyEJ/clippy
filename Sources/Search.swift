import Foundation

enum Search {
    /// Score for an item, or nil if no match. Higher is better.
    /// `hay` is the lowercased search text; `short` is its first ~2,000 characters, used for fuzzy and
    /// regex matching (both cost per character) so typing stays fast with large items. `q` is the lowercased query.
    static func score(_ hay: String, _ short: String, _ q: String, mode: SearchMode, regex: NSRegularExpression?) -> Int? {
        switch mode {
        case .exact:
            return contains(hay, q) ? 0 : nil
        case .regexp:
            return regexMatches(regex, short) ? 0 : nil
        case .fuzzy:
            return fuzzyScore(short, q)
        case .mixed:
            if contains(hay, q) { return 3_000_000 }
            if regexMatches(regex, short) { return 2_000_000 }
            return fuzzyScore(short, q)
        }
    }

    /// Byte-level substring search (memmem). Swift's String.contains compares grapheme by
    /// grapheme and is ~50x slower on long texts; both inputs here are already lowercased.
    static func contains(_ hay: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var h = hay, n = needle
        h.makeContiguousUTF8()
        n.makeContiguousUTF8()
        let found = h.utf8.withContiguousStorageIfAvailable { hb in
            n.utf8.withContiguousStorageIfAvailable { nb in
                memmem(hb.baseAddress, hb.count, nb.baseAddress, nb.count) != nil
            }
        }
        return (found ?? nil) ?? h.contains(n)
    }

    /// Fast fuzzy score over UTF-8 bytes, same scoring as `fuzzy` (used for filtering;
    /// highlighting uses the character-accurate `fuzzy`).
    static func fuzzyScore(_ hay: String, _ q: String) -> Int? {
        let qb = Array(q.utf8)
        guard !qb.isEmpty else { return nil }
        func isWordChar(_ c: UInt8) -> Bool { (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c >= 128 }
        var qi = 0, score = 0, i = 0, prevMatch = -2
        var prev: UInt8 = 32
        var started = false
        for c in hay.utf8 {
            if qi == qb.count { break }
            if c == qb[qi] {
                var s = 10
                if prevMatch == i - 1 { s += 15 }
                if !isWordChar(prev) { s += 10 }
                score += s
                prevMatch = i
                qi += 1
                started = true
            } else if started {
                score -= 1
            }
            prev = c
            i += 1
        }
        return qi == qb.count ? max(score, 1) : nil
    }

    private static func regexMatches(_ regex: NSRegularExpression?, _ s: String) -> Bool {
        guard let regex else { return false }
        return firstMatch(regex, in: s, timeout: 0.05) == true
    }

    /// Like `firstMatch(in:)`, but gives up after `timeout`: user-written patterns such as `(a+)+$`
    /// backtrack exponentially and would otherwise freeze the app. Returns nil when it ran out of time.
    static func firstMatch(_ re: NSRegularExpression, in s: String, timeout: TimeInterval) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        var found = false, timedOut = false, calls = 0
        re.enumerateMatches(in: s, options: [.reportProgress], range: NSRange(s.startIndex..., in: s)) { m, _, stop in
            calls += 1
            if m != nil {
                found = true
                stop.pointee = true
            } else if calls % 256 == 0 && Date() > deadline {   // progress fires about once per character; reading the clock each time tripled search cost
                timedOut = true
                stop.pointee = true
            }
        }
        return found ? true : (timedOut ? nil : false)
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

    /// Ranges in a display title to highlight. `q` is the query as typed (not lowercased,
    /// so regex escapes like \S and \D keep their meaning).
    static func ranges(in title: String, query q: String, mode: SearchMode, regex: NSRegularExpression?) -> [Range<String.Index>] {
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
        func regexRanges() -> [Range<String.Index>] {
            guard let regex else { return [] }
            var out: [Range<String.Index>] = []
            let deadline = Date().addingTimeInterval(0.02)
            regex.enumerateMatches(in: title, options: [.reportProgress], range: NSRange(title.startIndex..., in: title)) { m, _, stop in
                if let m, let r = Range(m.range, in: title), !r.isEmpty { out.append(r) }
                if Date() > deadline { stop.pointee = true }
            }
            return out
        }
        func fuzzy() -> [Range<String.Index>] {
            (Search.fuzzy(title, q.lowercased(), caseInsensitive: true)?.indices ?? []).map { $0..<title.index(after: $0) }
        }
        switch mode {
        case .exact: return exact()
        case .regexp: return regexRanges()
        case .fuzzy: return fuzzy()
        case .mixed:
            let e = exact(); if !e.isEmpty { return e }
            let r = regexRanges(); if !r.isEmpty { return r }
            return fuzzy()
        }
    }
}
