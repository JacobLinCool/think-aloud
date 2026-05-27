import XCTest
@testable import ThinkAloud

final class TextDiffTests: XCTestCase {
    func testEqualStringsProduceSingleEqualSegment() {
        let segs = TextDiff.diff(reference: "abc", hypothesis: "abc")
        XCTAssertEqual(segs.map { $0.op }, [.equal])
        XCTAssertEqual(segs.first?.text, "abc")
    }

    func testEmptyReferenceProducesAllInsertions() {
        let segs = TextDiff.diff(reference: "", hypothesis: "abc")
        XCTAssertEqual(segs.map { $0.op }, [.insert])
    }

    func testEmptyHypothesisProducesAllDeletions() {
        let segs = TextDiff.diff(reference: "abc", hypothesis: "")
        XCTAssertEqual(segs.map { $0.op }, [.delete])
    }

    func testSingleSubstitutionShowsAsDeleteThenInsert() {
        // kitten → sitting: ops include some substitutions reframed as delete+insert pairs.
        let segs = TextDiff.diff(reference: "abc", hypothesis: "abd")
        // Common prefix "ab" then delete "c" then insert "d".
        let opSequence = segs.map { $0.op }
        XCTAssertTrue(opSequence.contains(.equal))
        XCTAssertTrue(opSequence.contains(.delete))
        XCTAssertTrue(opSequence.contains(.insert))
    }

    func testChineseDiff() {
        let segs = TextDiff.diff(reference: "看起來實作上有點問題。", hypothesis: "看起來是做上了點問題。")
        // Walk segments and reconstruct ref/hyp from non-insert / non-delete ops respectively.
        var ref = ""
        var hyp = ""
        for s in segs {
            switch s.op {
            case .equal: ref += s.text; hyp += s.text
            case .delete: ref += s.text
            case .insert: hyp += s.text
            }
        }
        XCTAssertEqual(ref, "看起來實作上有點問題。")
        XCTAssertEqual(hyp, "看起來是做上了點問題。")
    }
}
