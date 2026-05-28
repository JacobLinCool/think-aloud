import Foundation

/// Pure text similarity helpers used by the benchmark. Character-level by design — CJK has
/// no word boundary so CER is the meaningful metric for ThinkAloud's main use cases.
enum TextMetrics {
    /// Controls how aggressively `normalize` strips formatting before comparing strings.
    /// `light` only collapses whitespace (preserving every character the model produced).
    /// `aggressive` mirrors the convention used by Whisper-style ASR benchmarks: lowercase,
    /// full-width → half-width, strip punctuation + symbols, collapse whitespace. The benchmark
    /// stores both variants per result so the UI can flip between strict and lenient scoring
    /// without re-running the model.
    enum NormalizationMode: String, Sendable, Codable {
        case light
        case aggressive
    }

    /// Character-level Levenshtein distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }

        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[m]
    }

    /// Character Error Rate. Anchored on the reference's length so deletions / insertions
    /// in the hypothesis both count proportionally.
    /// Empty reference: returns 0 if hypothesis also empty, else 1 (everything is insertion).
    static func cer(reference: String, hypothesis: String, mode: NormalizationMode = .light) -> Double {
        let ref = normalize(reference, mode: mode)
        let hyp = normalize(hypothesis, mode: mode)
        if ref.isEmpty { return hyp.isEmpty ? 0 : 1 }
        let d = editDistance(ref, hyp)
        return Double(d) / Double(ref.count)
    }

    /// Default light normalization: trim ends + collapse whitespace runs. Preserves case,
    /// punctuation, full-width characters. Used by everyday display paths.
    static func normalize(_ s: String) -> String {
        normalize(s, mode: .light)
    }

    static func normalize(_ s: String, mode: NormalizationMode) -> String {
        switch mode {
        case .light:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        case .aggressive:
            // 1) Full-width → half-width so "ＡＢＣ" and "ABC" match (also normalizes
            // full-width digits and punctuation, which are then mostly stripped below).
            let widthFolded = s.applyingTransform(StringTransform("Fullwidth-Halfwidth"), reverse: false) ?? s
            // 2) Strip punctuation + symbol categories. Covers ASCII (.,!?'"-) and CJK
            // (。、，「」『』！？……—) in one pass via Unicode general categories Pn/P*.
            var scalars = String.UnicodeScalarView()
            for u in widthFolded.unicodeScalars {
                if CharacterSet.punctuationCharacters.contains(u) { continue }
                if CharacterSet.symbols.contains(u) { continue }
                scalars.append(u)
            }
            let stripped = String(scalars)
            // 3) Lowercase ASCII (Unicode-aware so diacritics survive).
            let lowered = stripped.lowercased()
            // 4) Trim + collapse whitespace.
            let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
    }

    /// True iff normalized reference == normalized hypothesis.
    static func exactMatch(reference: String, hypothesis: String, mode: NormalizationMode = .light) -> Bool {
        normalize(reference, mode: mode) == normalize(hypothesis, mode: mode)
    }
}
