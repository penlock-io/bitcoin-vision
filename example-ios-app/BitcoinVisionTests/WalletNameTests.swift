import XCTest
@testable import BitcoinVision

final class WalletNameTests: XCTestCase {
    func test_names_are_trimmed() {
        XCTAssertEqual("Travel wallet", normalizedWalletName(input: "  Travel wallet \n"))
    }

    func test_empty_and_control_character_names_are_rejected() {
        for name in ["", " \t\n", "bad\nname", "bad\tname", "bad\u{0000}name"] {
            XCTAssertNil(normalizedWalletName(input: name))
        }
    }

    func test_names_have_a_forty_code_point_limit() {
        XCTAssertEqual(String(repeating: "x", count: 40), normalizedWalletName(input: String(repeating: "x", count: 40)))
        XCTAssertNil(normalizedWalletName(input: String(repeating: "x", count: 41)))
    }

    func test_supplementary_characters_count_once() {
        let symbol = "\u{1F3D5}"
        XCTAssertEqual(String(repeating: symbol, count: 40), normalizedWalletName(input: String(repeating: symbol, count: 40)))
        XCTAssertNil(normalizedWalletName(input: String(repeating: symbol, count: 41)))
    }
}
