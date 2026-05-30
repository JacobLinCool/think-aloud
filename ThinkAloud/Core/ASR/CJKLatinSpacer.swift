import Foundation

/// Auto Post-Edit typography step: inserts a single space at CJK ↔ half-width Latin/digit
/// boundaries ("盤古之白"), e.g. `測試ThinkAloud3` → `測試 ThinkAloud3` (only the CJK/Latin
/// seam gets a space; `ThinkAloud3` stays intact since both sides are Latin/digit).
///
/// Scope (v1): only ASCII letters and digits count as "Latin"; punctuation and existing
/// whitespace act as separators and never get an extra space. Full-/half-width punctuation
/// normalization is intentionally out of scope and may become a separate post-edit step.
enum CJKLatinSpacer {
    /// Reuses `TextMetrics.isCJK` so the script classification stays in one place.
    static func spaced(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count + 8)
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if let previous, needsSpace(between: previous, and: scalar) {
                out.append(" ")
            }
            out.append(scalar)
            previous = scalar
        }
        return String(out)
    }

    /// A boundary needs a space when exactly one side is CJK and the other is a half-width
    /// Latin letter or digit. CJK↔CJK, Latin↔Latin, and anything adjacent to whitespace or
    /// punctuation are left untouched, so spacing is never doubled.
    private static func needsSpace(between lhs: Unicode.Scalar, and rhs: Unicode.Scalar) -> Bool {
        (TextMetrics.isCJK(lhs) && isLatinOrDigit(rhs)) || (isLatinOrDigit(lhs) && TextMetrics.isCJK(rhs))
    }

    private static func isLatinOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39,   // 0-9
             0x41...0x5A,   // A-Z
             0x61...0x7A:   // a-z
            return true
        default:
            return false
        }
    }
}
