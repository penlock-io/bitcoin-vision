import XCTest
@testable import BitcoinVision

final class DetectionReviewTests: XCTestCase {
    private let source = DetectionSource(
        detectorId: 7, corners: [0, 0, 4, 0, 4, 3, 0, 3], parts: [], emptyReason: "no_ink_after_rules",
        recoveredWord: nil, decision: "owned_descender", localHeight: 20, supportIds: [], owner: nil, union: nil
    )

    private func with(_ change: (inout DetectionSource) -> Void) -> DetectionSource {
        var copy = source
        change(&copy)
        return copy
    }

    func test_geometry_only_ink_is_not_a_reading_but_a_recovery_is() {
        XCTAssertTrue(source.unread)
        XCTAssertEqual("Small ink belonging to a nearby word", source.reviewDescription)
        XCTAssertFalse(with { $0.recoveredWord = 4 }.unread)
        XCTAssertFalse(with { $0.parts = [DetectionPart(part: 0, corners: source.corners, wordIndex: 4)] }.unread)
        XCTAssertTrue(with { $0.parts = [DetectionPart(part: 0, corners: source.corners, wordIndex: nil)] }.unread)
        XCTAssertEqual("Region that could not be read", with { $0.decision = "too_few_supports" }.reviewDescription)
    }

    func test_both_selected_and_inactive_union_readings_account_for_the_ink() {
        for selected in [true, false] {
            let union = DetectionUnion(corners: source.corners, readFootprint: source.corners, wordIndex: 4,
                                       selected: selected, reason: selected ? "selected" : "uncertain")
            XCTAssertFalse(with { $0.decision = "detached_ending"; $0.union = union }.unread)
            var inactive = union
            inactive.wordIndex = nil
            inactive.selected = false
            inactive.reason = "read_budget"
            XCTAssertTrue(with { $0.decision = "detached_ending"; $0.union = inactive }.unread)
        }
    }
}
