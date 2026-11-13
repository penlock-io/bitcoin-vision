import XCTest
@testable import BitcoinVision

@MainActor
final class NewSeedBackupTests: XCTestCase {
    // Public, non-secret BIP39 test vectors; never funds.
    private let words = Array(repeating: "abandon", count: 11) + ["about"]
    private let other = "legal winner thank year wave sausage worth useful legal winner thank yellow"
        .split(separator: " ").map(String.init)

    private func photo() -> PhotoInput {
        PhotoInput.fromCamera(bytes: Data([1]), metadata: CameraPhotoMetadata(
            rotationDegrees: 0, width: 10, height: 10, format: 256,
            displayRotationAtShutter: 0, sensorToDisplayDegreesAtShutter: 0))
    }

    private func reading(_ words: [String], review: Bool = false) -> BackupReading {
        BackupReading(sequences: [.columns: words, .rows: words.reversed()], initial: .columns,
                      requiresOrderReview: review)
    }

    private func processing(_ flow: NewSeedBackup) -> Int {
        flow.retake()
        let token = flow.begin()
        let input = photo()
        XCTAssertTrue(flow.deliver(token: token, photo: input))
        XCTAssertTrue(flow.prepared(token: token, photo: ResolvedPhoto(source: input, orientation: 1, rawWidth: 10, rawHeight: 10)))
        return token
    }

    func test_exact_current_camera_read_is_reviewable_and_completion_is_one_use() {
        let flow = NewSeedBackup()
        flow.start(words: words)
        XCTAssertNil(flow.consumeVerified())
        XCTAssertEqual(-1, flow.begin())
        let token = processing(flow)
        XCTAssertNil(flow.consumeVerified())
        XCTAssertTrue(flow.finish(token: token, result: reading(words)))
        XCTAssertEqual(.verified, flow.stage)
        XCTAssertNotNil(flow.attempt) // retained for word/crop review until completion
        XCTAssertEqual(words, flow.consumeVerified())
        XCTAssertNil(flow.consumeVerified())
        XCTAssertTrue(flow.words.isEmpty)
        XCTAssertNil(flow.attempt)
    }

    func test_wrong_valid_phrase_missing_extra_and_transposed_are_not_accepted() {
        for read in [other, Array(words.dropLast()), words + ["about"], Array(words.reversed())] {
            let flow = NewSeedBackup()
            flow.start(words: words)
            flow.finish(token: processing(flow), result: reading(read))
            XCTAssertEqual(.review, flow.stage)
            XCTAssertNil(flow.consumeVerified())
            XCTAssertEqual(words, flow.words)
        }
    }

    func test_each_misread_requires_acknowledgement_and_never_changes_the_seed_or_scan() {
        var read = words
        read[0] = "ability"
        read[11] = "above"
        let flow = NewSeedBackup()
        flow.start(words: words)
        flow.finish(token: processing(flow), result: reading(read))
        flow.acknowledge(position: -1)
        flow.acknowledge(position: 12)
        flow.acknowledge(position: 1) // matching words do not need acknowledgement
        XCTAssertTrue(flow.acknowledged.isEmpty)
        flow.acknowledge(position: 0)
        XCTAssertNil(flow.consumeVerified())
        flow.acknowledge(position: 11)
        XCTAssertEqual(.verified, flow.stage)
        XCTAssertEqual(read, flow.readWords)
        XCTAssertEqual(words, flow.consumeVerified())
        XCTAssertNil(flow.consumeVerified())
    }

    func test_acknowledgement_does_not_bypass_missing_extra_order_or_failed_capture() {
        for read in [Array(words.dropLast()), words + ["about"]] {
            let flow = NewSeedBackup()
            flow.start(words: words)
            flow.finish(token: processing(flow), result: reading(read))
            (0...12).forEach { flow.acknowledge(position: $0) }
            XCTAssertNil(flow.consumeVerified())
        }
        let flow = NewSeedBackup()
        flow.start(words: words)
        var read = words
        read[0] = "ability"
        flow.finish(token: processing(flow), result: reading(read, review: true))
        flow.acknowledge(position: 0)
        XCTAssertTrue(flow.acknowledged.isEmpty)
        flow.chooseOrder(value: .columns)
        flow.acknowledge(position: 0)
        XCTAssertEqual(.verified, flow.stage)
        flow.chooseOrder(value: .rows)
        XCTAssertTrue(flow.acknowledged.isEmpty)
        XCTAssertNil(flow.consumeVerified())
        flow.retake()
        flow.acknowledge(position: 0)
        XCTAssertNil(flow.consumeVerified())
        XCTAssertTrue(flow.acknowledged.isEmpty)
    }

    func test_order_is_not_target_searched_and_an_explicit_transpose_is_allowed() {
        let flow = NewSeedBackup()
        flow.start(words: words)
        flow.finish(token: processing(flow), result: reading(Array(words.reversed())))
        XCTAssertEqual(.review, flow.stage)
        flow.chooseOrder(value: .numbers) // not supplied by this scan
        XCTAssertNil(flow.consumeVerified())
        flow.chooseOrder(value: .rows)
        XCTAssertEqual(words, flow.consumeVerified())
    }

    func test_order_review_requires_an_explicit_choice_even_when_initial_read_matches() {
        let flow = NewSeedBackup()
        flow.start(words: words)
        flow.finish(token: processing(flow), result: reading(words, review: true))
        XCTAssertNil(flow.consumeVerified())
        flow.chooseOrder(value: .columns)
        XCTAssertEqual(words, flow.consumeVerified())
    }

    func test_gallery_data_missing_photos_and_completion_before_preparation_fail_closed() {
        for input in [nil, PhotoInput.fromFile(bytes: Data([1]))] {
            let flow = NewSeedBackup()
            flow.start(words: words)
            flow.retake()
            let token = flow.begin()
            XCTAssertFalse(flow.finish(token: token, result: reading(words)))
            XCTAssertFalse(flow.deliver(token: token, photo: input))
            XCTAssertNil(flow.consumeVerified())
            XCTAssertEqual(.review, flow.stage)
        }
    }

    func test_retake_cancel_and_new_seed_reject_every_late_result() {
        let flow = NewSeedBackup()
        flow.start(words: words)
        let old = processing(flow)
        flow.showWords()
        XCTAssertEqual(words, flow.words)
        XCTAssertFalse(flow.finish(token: old, result: reading(words)))
        let next = processing(flow)
        XCTAssertFalse(flow.finish(token: old, result: reading(words)))
        flow.cancel()
        XCTAssertFalse(flow.finish(token: next, result: reading(words)))
        XCTAssertTrue(flow.words.isEmpty)
        flow.start(words: other)
        XCTAssertFalse(flow.finish(token: next, result: reading(other)))
        XCTAssertNil(flow.consumeVerified())
        XCTAssertEqual(.idle, NewSeedBackup().stage) // no process-death resume
    }

    func test_failed_attempt_retries_without_replacing_the_seed() {
        let flow = NewSeedBackup()
        flow.start(words: words)
        flow.fail(token: processing(flow))
        XCTAssertEqual(.review, flow.stage)
        XCTAssertEqual(words, flow.words)
        flow.finish(token: processing(flow), result: reading(words))
        XCTAssertEqual(words, flow.consumeVerified())
    }

    func test_native_selection_is_used_not_confidence_checks_or_edited_drafts() {
        let readings = words.map { word in
            WordReading(
                corners: Array(repeating: 0, count: 8), ranked: [], accepted: false, confidence: 0, alternatives: [],
                read: word, raw: "uncertain independent OCR", originalOcr: nil,
                matching: nil, labels: [], labelConflict: false, stray: false,
                number: nil, apart: false, cropPng: Data(), joinedFrom: [], expandedFrom: []
            )
        }
        let indices = readings.indices.map { UInt32($0) }
        let scan = PhraseScan(listNumbered: false, layout: .page, width: 100, height: 200, words: readings,
                              columns: indices, rows: indices.reversed(), columnsPass: false, rowsPass: false,
                              numbering: .none, numbered: indices, numberedPass: false, initialOrder: .columns,
                              orderRequiresReview: false, orderBasis: "longer_dimension", sources: [])
        let flow = NewSeedBackup()
        flow.start(words: words)
        flow.finish(token: processing(flow), result: BackupReading.from(scan: scan))
        XCTAssertEqual(words, flow.consumeVerified())
        XCTAssertTrue(scan.words.allSatisfy { !$0.accepted }) // no confidence promotion
    }
}
