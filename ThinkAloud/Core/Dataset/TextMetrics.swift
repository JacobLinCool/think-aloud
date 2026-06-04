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

    /// Character-level (grapheme) Levenshtein distance. Used by the benchmark CER/WER paths.
    static func editDistance(_ a: String, _ b: String) -> Int {
        editDistance(Array(a), Array(b))
    }

    /// Unicode-scalar Levenshtein distance. This is the canonical unit for ThinkAloud's dataset
    /// statistics: `isCJK`, `wordTokens`, and the per-script char split all iterate `unicodeScalars`,
    /// so measuring edit distance over scalars too keeps every stat on one axis (a grapheme-based
    /// distance would disagree with the scalar char counts for combining marks / emoji / ZWJ).
    static func editDistanceScalars(_ a: String, _ b: String) -> Int {
        editDistance(Array(a.unicodeScalars), Array(b.unicodeScalars))
    }

    /// Generic Levenshtein distance over any equatable token sequence — used both for
    /// character-level (`[Character]`) CER and word-level (`[String]`) WER.
    static func editDistance<T: Equatable>(_ aTokens: [T], _ bTokens: [T]) -> Int {
        let n = aTokens.count
        let m = bTokens.count
        if n == 0 { return m }
        if m == 0 { return n }

        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = aTokens[i - 1] == bTokens[j - 1] ? 0 : 1
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

    /// Word Error Rate. Word-level edit distance anchored on the reference's word count.
    /// CJK has no spaces, so `wordTokens` treats each ideograph as its own word while keeping
    /// Latin/digit runs grouped — the mixed-script convention jiwer-style benchmarks use. For
    /// pure-CJK text this collapses toward CER; for mixed/Latin content it is the meaningful
    /// word-level metric.
    /// Empty reference: returns 0 if hypothesis also empty, else 1.
    static func wer(reference: String, hypothesis: String, mode: NormalizationMode = .light) -> Double {
        let ref = wordTokens(normalize(reference, mode: mode))
        let hyp = wordTokens(normalize(hypothesis, mode: mode))
        if ref.isEmpty { return hyp.isEmpty ? 0 : 1 }
        let d = editDistance(ref, hyp)
        return Double(d) / Double(ref.count)
    }

    /// Splits already-normalized text into "words" for WER. Each CJK ideograph / kana becomes
    /// its own token; consecutive non-CJK characters (Latin letters, digits, residual
    /// punctuation) group into one token; whitespace separates tokens. So
    /// "build a GitHub 網站" → ["build", "a", "GitHub", "網", "站"].
    static func wordTokens(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        for u in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(u) {
                flush()
            } else if isCJK(u) {
                flush()
                tokens.append(String(u))
            } else {
                current.append(u)
            }
        }
        flush()
        return tokens
    }

    /// True for characters that stand alone as a "word" in CJK text: ideographs (incl.
    /// extensions A/B and compatibility forms) plus Japanese kana.
    /// Exposed (internal) so the Auto Post-Edit typography step (`CJKLatinSpacer`) can reuse
    /// the same script classification instead of duplicating the Unicode ranges.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,    // Hiragana + Katakana
             0x3400...0x4DBF,    // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0x20000...0x2A6DF,  // CJK Unified Ideographs Extension B
             0x2F800...0x2FA1F:  // CJK Compatibility Ideographs Supplement
            return true
        default:
            return false
        }
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
