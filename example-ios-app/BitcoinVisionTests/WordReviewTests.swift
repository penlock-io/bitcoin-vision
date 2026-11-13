import XCTest
@testable import BitcoinVision

final class WordReviewTests: XCTestCase {
    private func leftover(_ raw: String, conflict: Bool = false, ambiguous: Bool = false, stray: Bool = true) -> Entry {
        Entry(
            id: 0, word: "eight",
            source: Source(corners: Array(repeating: 0, count: 8), ranked: [("eight", 0.1)], accepted: false,
                           cropPng: Data(), read: "eight", raw: raw, stray: stray,
                           labels: ambiguous ? [ObservedLabel(literal: raw, ordinal: 8, origin: "standalone", ambiguous: true)] : [],
                           labelConflict: conflict),
            checked: false
        )
    }

    func test_standalone_labels_are_not_unresolved_text_but_ambiguous_or_prefixed_words_remain() {
        for raw in ["8.", " 12. ", "24)"] { XCTAssertTrue(leftover(raw).isObviousNumberLabel, raw) }
        for raw in ["8. iron", "eight", "q", "8", "25.", "0.", "."] { XCTAssertFalse(leftover(raw).isObviousNumberLabel, raw) }
        XCTAssertFalse(leftover("8.", conflict: true).isObviousNumberLabel)
        XCTAssertFalse(leftover("8.", ambiguous: true).isObviousNumberLabel)
        XCTAssertFalse(leftover("8.", stray: false).isObviousNumberLabel)
        var renamed = leftover("8.")
        renamed.word = "iron"
        XCTAssertFalse(renamed.isObviousNumberLabel)
        let sources = [leftover("8.").source!, leftover("something").source!]
        let draft = PhraseDraft(boxes: sources, columns: [0, 1], rows: [0, 1], order: .columns)
        XCTAssertEqual(2, draft.leftOut.count) // diagnostic evidence is not removed
        XCTAssertEqual([1], draft.reviewLeftOut.map(\.id))
    }

    func test_preview_bounds_include_every_word_with_margin_and_clamp_to_photo() {
        func quad(_ l: Float, _ t: Float, _ r: Float, _ b: Float) -> [Float] { [l, t, r, t, r, b, l, b] }
        let frame = PhotoFrame(width: 1000, height: 800)
        XCTAssertEqual(ReviewPhotoBounds(left: 184, top: 84, width: 432, height: 432),
                       reviewPhotoBounds(frame: frame, quads: [quad(200, 100, 400, 200), quad(450, 400, 600, 500)]))
        XCTAssertEqual(ReviewPhotoBounds(left: 0, top: 0, width: 1000, height: 800), reviewPhotoBounds(frame: frame, quads: []))
        XCTAssertEqual(ReviewPhotoBounds(left: 0, top: 0, width: 1000, height: 800),
                       reviewPhotoBounds(frame: frame, quads: [Array(repeating: Float.nan, count: 8)]))
        let edge = reviewPhotoBounds(frame: frame, quads: [quad(-10, -20, 995, 810)])
        XCTAssertEqual(ReviewPhotoBounds(left: 0, top: 0, width: 1000, height: 800), edge)
    }

    func test_confidence_belongs_to_displayed_word_and_unknown_is_not_zero_or_top_probability() {
        // The word model prefers cat; the scanner read dog and gives it .7.
        let source = Source(corners: Array(repeating: 0, count: 8), ranked: [("cat", 0.8), ("dog", 0.2)],
                            accepted: false, cropPng: Data(), read: "dog", confidence: 0.7, alternatives: [("cat", 0.3)])
        let word = Entry(id: 0, word: "dog", source: source, checked: false)
        XCTAssertEqual(0.7, word.modelConfidence)
        var cat = word; cat.word = "cat"
        XCTAssertEqual(0.3, cat.modelConfidence)
        var zoo = word; zoo.word = "zoo"
        XCTAssertNil(zoo.modelConfidence)
        var typed = word; typed.source = nil
        XCTAssertNil(typed.modelConfidence)
        let invalid = Source(corners: Array(repeating: 0, count: 8), ranked: [], accepted: false, cropPng: Data(),
                             read: "dog", confidence: .nan)
        var unknown = word; unknown.source = invalid
        XCTAssertNil(unknown.modelConfidence)
    }

    private func entry(_ id: Int, _ accepted: Bool, _ read: String = "cat") -> Entry {
        Entry(id: id, word: read,
              source: Source(corners: Array(repeating: 0, count: 8), ranked: [("cat", 0.8)], accepted: accepted,
                             cropPng: Data(), read: read),
              checked: false)
    }

    func test_attention_uses_the_existing_scanner_verdict_and_correction_state() {
        XCTAssertTrue(entry(0, false).needsAttention)
        XCTAssertFalse(entry(0, true).needsAttention)
        var corrected = entry(0, false); corrected.word = "dog"
        XCTAssertFalse(corrected.needsAttention)
        XCTAssertFalse(Entry(id: 2, word: "dog", source: nil, checked: false).needsAttention)
        // Recogniser-origin picks keep the scanner's verdict; no probability cutoff here.
        XCTAssertTrue(entry(0, false, "dog").needsAttention)
        XCTAssertFalse(entry(0, true, "dog").needsAttention)
    }
}
