import Foundation

/// Character-level diff for displaying ground-truth vs prediction side-by-side. We compute the
/// longest common subsequence (LCS) and walk it to emit a sequence of segments tagged with
/// equal/insert/delete operations. The benchmark UI renders these as colored runs so the user
/// can immediately see *what* the model got wrong, not just the CER number.
enum TextDiff {
    enum Op: Sendable, Equatable {
        case equal
        case insert   // present in hypothesis, missing from reference
        case delete   // present in reference, missing from hypothesis
    }

    struct Segment: Sendable, Equatable {
        let op: Op
        let text: String
    }

    /// Diffs `reference` (ground truth) against `hypothesis` (prediction). The returned array
    /// concatenates back to `reference + insertions - deletions`, broken into runs that share an op.
    static func diff(reference: String, hypothesis: String) -> [Segment] {
        let a = Array(reference)
        let b = Array(hypothesis)
        let n = a.count
        let m = b.count
        if n == 0 {
            return b.isEmpty ? [] : [Segment(op: .insert, text: hypothesis)]
        }
        if m == 0 {
            return [Segment(op: .delete, text: reference)]
        }

        // LCS DP table — rows correspond to a, cols to b.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if a[i] == b[j] {
                    lcs[i + 1][j + 1] = lcs[i][j] + 1
                } else {
                    lcs[i + 1][j + 1] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        // Walk back to produce ops, then reverse and coalesce.
        var i = n, j = m
        var rawOps: [(Op, Character)] = []
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                rawOps.append((.equal, a[i - 1]))
                i -= 1; j -= 1
            } else if lcs[i - 1][j] >= lcs[i][j - 1] {
                rawOps.append((.delete, a[i - 1]))
                i -= 1
            } else {
                rawOps.append((.insert, b[j - 1]))
                j -= 1
            }
        }
        while i > 0 { rawOps.append((.delete, a[i - 1])); i -= 1 }
        while j > 0 { rawOps.append((.insert, b[j - 1])); j -= 1 }
        rawOps.reverse()

        // Coalesce adjacent ops of the same kind.
        var segments: [Segment] = []
        var currentOp: Op?
        var buffer = ""
        for (op, ch) in rawOps {
            if op == currentOp {
                buffer.append(ch)
            } else {
                if let prev = currentOp {
                    segments.append(Segment(op: prev, text: buffer))
                }
                currentOp = op
                buffer = String(ch)
            }
        }
        if let prev = currentOp {
            segments.append(Segment(op: prev, text: buffer))
        }
        return segments
    }
}
