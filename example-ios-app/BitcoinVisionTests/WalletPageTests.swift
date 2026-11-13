import XCTest
@testable import BitcoinVision

final class WalletPageTests: XCTestCase {
    func test_the_primary_button_follows_the_next_action_with_review_first() {
        XCTAssertEqual(Primary.review, primaryFor(next: .review))
        XCTAssertEqual(Primary.backUp, primaryFor(next: .backUp))
        XCTAssertEqual(Primary.sign, primaryFor(next: .sign))
        XCTAssertEqual(Primary.scan, primaryFor(next: .loadKey))
    }

    func test_the_unloaded_primary_is_the_camera_under_the_old_load_tag() {
        XCTAssertEqual("Scan phrase", Primary.scan.label)
        XCTAssertEqual("load-wallet-key", Primary.scan.tag)
        XCTAssertEqual("Sign a transaction", Primary.sign.label)
        XCTAssertEqual("Back up this wallet", Primary.backUp.label)
        XCTAssertEqual("Review transaction", Primary.review.label)
    }

    func test_provenance_and_backup_labels_are_short_facts_not_sentences() {
        XCTAssertEqual("from written phrase", KeySource.writtenPhrase.provenance())
        XCTAssertEqual("from strips 1 and 3", KeySource.strips(first: 3, second: 1).provenance())
        XCTAssertEqual("made on this phone", KeySource.new.provenance())
        XCTAssertEqual("Backup not checked", backupLabel(checked: nil))
        XCTAssertEqual("Backup checked 3 Sep 2026", backupLabel(checked: "2026-09-03"))
    }

    func test_every_fixed_line_on_the_wallet_pages_is_at_most_one_sentence() {
        let lines = [BACKUP_WARNING_LINE, SAFETY_LINE] + Primary.allCases.map(\.label) +
            [backupLabel(checked: nil), KeySource.new.provenance()]
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            let sentences = trimmed.components(separatedBy: ". ").count
            XCTAssertTrue(sentences <= (line == SAFETY_LINE ? 2 : 1), "'\(line)' has \(sentences) sentences")
        }
    }

    func test_unload_is_authorised_by_travel_at_release_not_by_the_proposed_target() {
        let width = 1000
        XCTAssertTrue(unloadRequested(offset: -1000, width: width, loaded: true))
        XCTAssertTrue(unloadRequested(offset: -(Float(width) * UNLOAD_TRAVEL), width: width, loaded: true))
        XCTAssertFalse(unloadRequested(offset: -400, width: width, loaded: true), "a 40 % drag")
        XCTAssertFalse(unloadRequested(offset: -250, width: width, loaded: true), "a short fast fling")
        XCTAssertFalse(unloadRequested(offset: 1000, width: width, loaded: true), "rightward travel")
        XCTAssertFalse(unloadRequested(offset: -1000, width: width, loaded: false), "no key to unload")
        XCTAssertFalse(unloadRequested(offset: -1000, width: 0, loaded: true), "before the first layout")
        XCTAssertTrue(UNLOAD_TRAVEL >= 0.85)
    }
}
