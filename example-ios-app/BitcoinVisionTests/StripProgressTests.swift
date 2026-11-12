import XCTest
@testable import BitcoinVision

final class StripProgressTests: XCTestCase {
    func test_stages_and_geometry_replay_in_order_before_review() throws {
        let stream = StripProgressHandoff(token: 7)
        var sequence: UInt64 = 0
        func send(_ update: StripProgressUpdate) throws {
            sequence += 1
            try stream.onProgress(event: StripProgressEvent(sequence: sequence, update: update))
        }
        try send(.work(phase: .admitting, completed: 0, total: nil))
        try send(.photo(width: 600, height: 1200))
        try send(.work(phase: .locating, completed: 0, total: nil))
        try send(.work(phase: .identifying, completed: 0, total: 1))
        try send(.region(id: 0, corners: [1.0, 2.0, 3.0, 2.0, 3.0, 4.0, 1.0, 4.0], read: false))
        try send(.work(phase: .identifying, completed: 1, total: 1))
        try send(.work(phase: .reading, completed: 0, total: 1))
        try send(.region(id: 0, corners: [1.0, 2.0, 3.0, 2.0, 3.0, 4.0, 1.0, 4.0], read: true))
        try send(.work(phase: .reading, completed: 1, total: 1))
        try send(.work(phase: .packing, completed: 0, total: 1))
        try send(.work(phase: .packing, completed: 1, total: 1))
        try send(.finished)
        try stream.sealSuccess()
        var shown = try XCTUnwrap(stream.snapshot())
        XCTAssertEqual(0, shown.sequence)
        var clock: Int64 = 0
        while !shown.finished {
            stream.presented(sequence: shown.sequence, nowMs: clock)
            clock += Int64(PROGRESS_STAGE_MS) + 1
            shown = try XCTUnwrap(stream.nextFrame(nowMs: clock))
        }
        XCTAssertEqual(sequence, shown.sequence)
        XCTAssertTrue(try XCTUnwrap(shown.regions[0]).read)
        XCTAssertEqual(Set(StripWorkPhase.entries), shown.stages)
        XCTAssertEqual(PhotoFrame(width: 600, height: 1200), shown.frame)
        stream.presented(sequence: shown.sequence, nowMs: clock)
        XCTAssertTrue(stream.playbackComplete(nowMs: clock + Int64(PROGRESS_STAGE_MS) + 1))
    }

    func test_truncated_stream_cannot_enter_review() throws {
        let stream = StripProgressHandoff(token: 1)
        try stream.onProgress(event: StripProgressEvent(sequence: 1, update: .photo(width: 50, height: 50)))
        try stream.onProgress(event: StripProgressEvent(sequence: 2, update: .finished))
        XCTAssertThrowsError(try stream.sealSuccess(), "Incomplete stages accepted") { error in
            XCTAssertTrue(error is StripProgressError)
        }
    }

    func test_malformed_geometry_is_rejected_before_it_can_be_drawn() throws {
        let stream = StripProgressHandoff(token: 2)
        try stream.onProgress(event: StripProgressEvent(sequence: 1, update: .photo(width: 50, height: 50)))
        XCTAssertThrowsError(
            try stream.onProgress(event: StripProgressEvent(sequence: 2, update: .region(id: 0, corners: [1.0, 2.0], read: false))),
            "Malformed region accepted"
        ) { error in
            XCTAssertEqual(error as? ProgressDeliveryError, .Failed)
        }
    }
}
