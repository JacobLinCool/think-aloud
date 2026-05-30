import Foundation

/// Compiled form of the user's custom dictionary (the final Auto Post-Edit step).
///
/// Matching is **longest-match-first at each position**, via a single left-to-right pass over
/// grapheme clusters (`[Character]`). The cursor advances past the consumed source and the output
/// is append-only and never re-scanned, so:
///   • a replacement can never trigger another rule (no cascade, e.g. `a`→`aa` terminates), and
///   • the result is independent of the order rules were entered.
/// Rules are dispatched by their ASCII-folded first `Character` into buckets pre-sorted by
/// descending `from` length (ties broken by unicode-scalar order then stored index — a total,
/// deterministic order). Latin A–Z match case-insensitively; CJK and all other characters match
/// by exact `Character` equality (no case/width folding).
///
/// Build this ONCE per config snapshot (it is derived state, not Codable) and reuse it across the
/// many per-token `apply` calls during streaming — never recompile per token.
struct CompiledDictionary: Sendable {
    private struct Entry { let from: [Character]; let to: [Character] }
    private let buckets: [Character: [Entry]]
    let isEmpty: Bool

    /// ASCII-only lowercasing; CJK / emoji / punctuation pass through unchanged.
    @inline(__always)
    static func key(_ c: Character) -> Character {
        let scalars = c.unicodeScalars
        guard scalars.count == 1, let v = scalars.first?.value, (0x41...0x5A).contains(v) else { return c }
        return Character(Unicode.Scalar(v + 0x20)!)
    }

    init(_ rules: [DictionaryRule]) {
        var seen = Set<[Character]>()            // dedupe on ASCII-folded grapheme array
        var b: [Character: [Entry]] = [:]
        for rule in rules where rule.enabled && !rule.isBlank {
            let from = Array(rule.from)
            guard seen.insert(from.map(Self.key)).inserted else { continue }   // first-wins, stable
            guard let first = from.first else { continue }
            b[Self.key(first), default: []].append(Entry(from: from, to: Array(rule.to)))
        }
        for k in b.keys {
            b[k]!.sort {
                if $0.from.count != $1.from.count { return $0.from.count > $1.from.count }
                return String($0.from).unicodeScalars.lexicographicallyPrecedes(String($1.from).unicodeScalars)
            }
        }
        buckets = b
        isEmpty = b.isEmpty
    }

    func apply(to text: String) -> String {
        if isEmpty { return text }
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            var matched: Entry?
            if let bucket = buckets[Self.key(chars[i])] {
                outer: for e in bucket {
                    guard i + e.from.count <= chars.count else { continue }
                    var j = 0
                    while j < e.from.count {
                        if Self.key(chars[i + j]) != Self.key(e.from[j]) { continue outer }
                        j += 1
                    }
                    matched = e                       // first hit in a longest-first bucket == longest here
                    break
                }
            }
            if let e = matched {
                out.append(contentsOf: e.to)
                i += e.from.count                     // skip the consumed source; never re-scan output
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// Advisory: is `from` short enough to risk firing inside unrelated words? Script-aware —
    /// a lone CJK character (e.g. 四) or a 1–2 char Latin token (e.g. go, ai) are the footguns.
    /// Blank rules and identity rules (from == to) never warn. Used only by the Settings UI.
    static func isShortTerm(_ rule: DictionaryRule) -> Bool {
        let trimmed = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rule.from != rule.to else { return false }
        let chars = Array(trimmed)
        let cjk = chars.filter { $0.unicodeScalars.first.map(TextMetrics.isCJK) ?? false }.count
        let cjkDominant = cjk * 2 >= chars.count
        return cjkDominant ? chars.count <= 1 : chars.count <= 2
    }
}
