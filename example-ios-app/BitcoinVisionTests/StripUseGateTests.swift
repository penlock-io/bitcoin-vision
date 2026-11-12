import XCTest
@testable import BitcoinVision

final class StripUseGateTests: XCTestCase {
    private func pair(_ statuses: CombinedRowStatus...) -> CombinedStripReview {
        CombinedStripReview(rows: (0..<12).map { index in
            CombinedRowReview(number: UInt32(index + 1),
                              status: index < statuses.count ? statuses[index] : .exact,
                              position: nil, observed: nil, expected: nil)
        })
    }

    func test_first_share_can_be_held_without_a_pair_check() {
        XCTAssertTrue(shareUseAllowed(firstShareHeld: false, pair: nil, paperChecked: false))
    }

    func test_second_share_requires_a_fresh_valid_pair_check() {
        XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: nil, paperChecked: false))
        XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: nil, paperChecked: true))
        XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: CombinedStripReview(rows: []), paperChecked: true))
        XCTAssertTrue(shareUseAllowed(firstShareHeld: true, pair: pair(.exact), paperChecked: false))
    }

    func test_correction_or_uncertainty_requires_paper_check_before_use() {
        for status in [CombinedRowStatus.corrected, .needsReview] {
            let changed = pair(.exact, status)
            XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: changed, paperChecked: false))
            XCTAssertTrue(shareUseAllowed(firstShareHeld: true, pair: changed, paperChecked: true))
        }
        // Retaking or editing invalidates the old check; acknowledgement alone
        // cannot authorize a result that has not been recomputed.
        XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: nil, paperChecked: true))
    }

    func test_edit_then_retake_never_reuses_the_previous_pair_or_paper_check() {
        let exact = pair(.exact)
        let edited = pair(.corrected)
        XCTAssertTrue(shareUseAllowed(firstShareHeld: false, pair: nil, paperChecked: false)) // hold the first share
        XCTAssertTrue(shareUseAllowed(firstShareHeld: true, pair: exact, paperChecked: false))
        XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: edited, paperChecked: false)) // an edit needs paper review
        XCTAssertTrue(shareUseAllowed(firstShareHeld: true, pair: edited, paperChecked: true))
        XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: nil, paperChecked: true)) // retake discards that pair
        XCTAssertFalse(shareUseAllowed(firstShareHeld: true, pair: edited, paperChecked: false)) // the new capture starts unchecked
    }
}
