import XCTest
@testable import ThinkAloud

final class CustomDictionaryTests: XCTestCase {
    /// Build a compiled dictionary from (from, to) pairs (all enabled).
    private func dict(_ pairs: [(String, String)]) -> CompiledDictionary {
        CompiledDictionary(pairs.map { DictionaryRule(from: $0.0, to: $0.1) })
    }

    func testLongestMatchFirstShadowing() {
        // The core requirement: a longer term wins over a shorter one at the same position.
        let d = dict([("四", "4"), ("gpt四", "GPT-4")])
        XCTAssertEqual(d.apply(to: "用gpt四寫"), "用GPT-4寫")
    }

    func testCJKTerm() {
        XCTAssertEqual(dict([("歐拉", "Euler")]).apply(to: "歐拉公式"), "Euler公式")
    }

    func testASCIICaseInsensitive() {
        let d = dict([("react", "React")])
        XCTAssertEqual(d.apply(to: "用REACT框架"), "用React框架")
        XCTAssertEqual(d.apply(to: "react"), "React")
    }

    func testNoSelfCascade() {
        // `a`→`aa` must terminate (output never re-scanned).
        XCTAssertEqual(dict([("a", "aa")]).apply(to: "abc"), "aabc")
    }

    func testNoCrossCascade() {
        // Once `react` is consumed and `React` emitted, `React`→X must NOT fire.
        XCTAssertEqual(dict([("react", "React"), ("React", "X")]).apply(to: "react"), "React")
    }

    func testEmptyReplacementDeletes() {
        XCTAssertEqual(dict([("嗯", "")]).apply(to: "我嗯覺得"), "我覺得")
    }

    func testLongestAtPosition() {
        XCTAssertEqual(dict([("bc", "Y"), ("ab", "X")]).apply(to: "abc"), "Xc")
    }

    func testGraphemeClusterEmoji() {
        // A ZWJ family emoji is one Character and must not be matched as the man emoji inside it.
        let d = dict([("👨‍👩‍👧", "family"), ("👨", "man")])
        XCTAssertEqual(d.apply(to: "👨‍👩‍👧好"), "family好")
    }

    func testDuplicateFirstWins() {
        let d = CompiledDictionary([
            DictionaryRule(from: "ai", to: "A"),
            DictionaryRule(from: "ai", to: "B"),
        ])
        XCTAssertEqual(d.apply(to: "ai"), "A")
    }

    func testWhitespaceOnlyFromSkipped() {
        XCTAssertEqual(dict([("  ", "X")]).apply(to: "a  b"), "a  b")
    }

    func testFromLongerThanRemaining() {
        XCTAssertEqual(dict([("abcdef", "X")]).apply(to: "abc"), "abc")
    }

    func testDisabledRuleInert() {
        let d = CompiledDictionary([DictionaryRule(from: "react", to: "React", enabled: false)])
        XCTAssertEqual(d.apply(to: "react"), "react")
    }

    func testCJKTraditionalSimplifiedDistinct() {
        // ASCII-only case folding must never conflate distinct CJK characters.
        XCTAssertEqual(dict([("歐", "X")]).apply(to: "欧"), "欧")
    }

    func testReplacementEmittedVerbatim() {
        XCTAssertEqual(dict([("x", "GPT-4")]).apply(to: "x"), "GPT-4")
    }

    func testEmptyDictionaryIdentity() {
        let d = CompiledDictionary([])
        XCTAssertTrue(d.isEmpty)
        XCTAssertEqual(d.apply(to: "任意text"), "任意text")
    }

    // MARK: - isShortTerm advisory

    func testIsShortTerm() {
        XCTAssertTrue(CompiledDictionary.isShortTerm(DictionaryRule(from: "四", to: "4")))      // CJK <= 1
        XCTAssertFalse(CompiledDictionary.isShortTerm(DictionaryRule(from: "歐拉", to: "Euler"))) // CJK == 2
        XCTAssertTrue(CompiledDictionary.isShortTerm(DictionaryRule(from: "go", to: "Go")))      // Latin <= 2
        XCTAssertFalse(CompiledDictionary.isShortTerm(DictionaryRule(from: "react", to: "React")))// Latin >= 3
        XCTAssertFalse(CompiledDictionary.isShortTerm(DictionaryRule(from: "", to: "x")))        // blank
        XCTAssertFalse(CompiledDictionary.isShortTerm(DictionaryRule(from: "四", to: "四")))      // from == to
    }
}
