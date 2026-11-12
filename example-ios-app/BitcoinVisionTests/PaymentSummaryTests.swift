import XCTest
@testable import BitcoinVision

final class PaymentSummaryTests: XCTestCase {
    func test_leaving_is_payments_plus_fee_including_multiple_recipients() {
        XCTAssertEqual(41_000, totalLeaving(amounts: [40_000], fee: 1_000))
        XCTAssertEqual(51_000, totalLeaving(amounts: [40_000, 10_000], fee: 1_000))
    }

    func test_all_change_still_pays_a_fee() {
        XCTAssertEqual(1_000, totalLeaving(amounts: [], fee: 1_000))
        XCTAssertEqual(0, totalLeaving(amounts: [], fee: 0))
    }

    func test_amounts_use_grouped_satoshis_without_losing_precision() {
        XCTAssertEqual("2,100,000,000,000,000 sats", sats(n: 2_100_000_000_000_000))
        XCTAssertEqual("1,000 sats", sats(n: 1_000))
    }
}
