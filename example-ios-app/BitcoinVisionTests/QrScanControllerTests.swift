import XCTest
@testable import BitcoinVision

final class QrScanControllerTests: XCTestCase {
    private let frame = QrFrame(width: 4, height: 4, rowStride: 4, luma: Data(count: 16))
    private let psbt = Data([0x70, 0x73, 0x62, 0x74, 0xFF])

    private struct DecoderGone: Error {}

    /** The main thread as a queue the test drains by hand. */
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [() -> Void] = []
        private var _delivered: [QrScan] = []
        private var _releases = 0
        var controller: QrScanController!

        init(decode: @escaping (QrFrame) throws -> QrScan) {
            controller = QrScanController(
                decode: decode,
                release: { [unowned self] in lock.withLock { _releases += 1 } },
                post: { [unowned self] work in lock.withLock { queue.append(work) } },
                onScan: { [unowned self] scan in lock.withLock { _delivered.append(scan) } }
            )
        }

        var delivered: [QrScan] { lock.withLock { _delivered } }
        var releases: Int { lock.withLock { _releases } }
        var queued: Int { lock.withLock { queue.count } }

        func drain() {
            while let work = lock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) { work() }
        }
    }

    private func blocking(_ result: QrScan, _ started: DispatchSemaphore, _ release: DispatchSemaphore) -> (QrFrame) throws -> QrScan {
        { _ in
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return result
        }
    }

    /** Runs `work` on another thread; the returned semaphore signals when it finishes. */
    private func thread(_ work: @escaping () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }.start()
        return done
    }

    func test_a_frame_arriving_while_one_decodes_is_dropped() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let h = Harness(decode: blocking(.progress(partsSeen: 1, partsExpected: 4, fraction: 0.14), started, release))
        let frame = self.frame
        var taken = false
        let worker = thread { taken = h.controller.offer(frame: frame) }
        _ = started.wait(timeout: .now() + 5)
        XCTAssertFalse(h.controller.offer(frame: frame), "the second frame is dropped, not queued")
        release.signal()
        _ = worker.wait(timeout: .now() + 5)
        XCTAssertTrue(taken)
        h.drain()
        XCTAssertEqual([QrScan.progress(partsSeen: 1, partsExpected: 4, fraction: 0.14)], h.delivered)
        release.signal()
        XCTAssertTrue(h.controller.offer(frame: frame))
        XCTAssertEqual(0, h.releases)
    }

    func test_the_first_decoded_psbt_is_the_last_thing_delivered() {
        var decodes = 0
        let psbt = self.psbt
        let h = Harness { _ in
            decodes += 1
            return .decoded(psbt: psbt)
        }
        XCTAssertTrue(h.controller.offer(frame: frame))
        XCTAssertFalse(h.controller.offer(frame: frame))
        XCTAssertFalse(h.controller.offer(frame: frame))
        h.drain()
        XCTAssertEqual([QrScan.decoded(psbt: psbt)], h.delivered)
        XCTAssertEqual(1, decodes, "frames after the latch never reach the decoder")
    }

    func test_a_decode_queued_for_delivery_is_dropped_when_the_session_retires_first() {
        let psbt = self.psbt
        let h = Harness { _ in .decoded(psbt: psbt) }
        XCTAssertTrue(h.controller.offer(frame: frame))
        XCTAssertEqual(1, h.queued, "delivery is waiting on the main queue")
        h.controller.retire()
        h.drain()
        XCTAssertTrue(h.delivered.isEmpty, "nothing reached the screen after Back")
        XCTAssertEqual(1, h.releases)
        XCTAssertFalse(h.controller.offer(frame: frame))
    }

    func test_retiring_between_admission_and_the_native_call_waits_for_it_to_finish() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let h = Harness(decode: blocking(.decoded(psbt: psbt), started, release))
        let frame = self.frame
        let worker = thread { h.controller.offer(frame: frame) }
        _ = started.wait(timeout: .now() + 5)
        h.controller.retire()
        XCTAssertEqual(0, h.releases, "the decoder stays alive while a frame is inside it")
        XCTAssertTrue(h.controller.retired)
        release.signal()
        _ = worker.wait(timeout: .now() + 5)
        XCTAssertEqual(1, h.releases, "released once, by the worker, after the call returned")
        h.drain()
        XCTAssertTrue(h.delivered.isEmpty)
        h.controller.retire()
        XCTAssertEqual(1, h.releases, "retire is idempotent")
    }

    func test_a_decode_that_throws_is_a_dropped_frame_and_cleanup_still_happens() {
        var attempts = 0
        let h = Harness { _ in
            attempts += 1
            if attempts == 1 { throw DecoderGone() }
            return .progress(partsSeen: 1, partsExpected: 2, fraction: 0.29)
        }
        XCTAssertTrue(h.controller.offer(frame: frame))
        h.drain()
        XCTAssertTrue(h.delivered.isEmpty)
        XCTAssertTrue(h.controller.offer(frame: frame), "the worker is free again")
        h.drain()
        XCTAssertEqual([QrScan.progress(partsSeen: 1, partsExpected: 2, fraction: 0.29)], h.delivered)
        h.controller.retire()
        XCTAssertEqual(1, h.releases)
    }

    func test_the_ring_follows_progress_and_a_stray_code_only_adds_a_notice() {
        let ring = QrScanState().after(scan: .progress(partsSeen: 3, partsExpected: 8, fraction: 0.21))
        XCTAssertEqual(QrScanState(fraction: 0.21, partsSeen: 3, partsExpected: 8, notice: nil), ring)
        let strayed = ring.after(scan: .rejected(reason: "QR is a ur:crypto-seed, not a PSBT"))
        var expected = ring
        expected.notice = "QR is a ur:crypto-seed, not a PSBT"
        XCTAssertEqual(expected, strayed)
        let resumed = strayed.after(scan: .progress(partsSeen: 4, partsExpected: 8, fraction: 0.29))
        XCTAssertNil(resumed.notice, "the next real part clears the notice")
        XCTAssertEqual(1, resumed.after(scan: .decoded(psbt: psbt)).fraction)
    }
}
