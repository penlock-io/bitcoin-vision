import Foundation

/** One camera frame's luma plane, rows `rowStride` bytes apart. */
struct QrFrame {
    let width: Int
    let height: Int
    let rowStride: Int
    let luma: Data
}

/**
 * One scanning session's whole lifetime under one lock: which frames
 * are admitted, what is delivered, and when the native decoder is
 * released.
 *
 * One frame decodes at a time and the rest are dropped. The first
 * decoded PSBT is the last result delivered. `retire` ends the session
 * at once: nothing admitted afterwards, nothing already queued for
 * delivery reaches `onScan`, and a decode under way is finished quietly.
 * `release` runs exactly once, only when no decode is admitted — on the
 * retiring thread if the worker is idle, otherwise on the worker when it
 * finishes — so the decoder is never destroyed between a frame's
 * admission and its native call. A decode that throws counts as a
 * dropped frame.
 */
final class QrScanController: @unchecked Sendable {
    private let decode: (QrFrame) throws -> QrScan
    private let release: () -> Void
    private let post: (@escaping () -> Void) -> Void
    private let onScan: (QrScan) -> Void

    private let lock = NSLock()
    private var busy = false
    private var latched = false
    private var closed = false
    private var released = false

    init(
        decode: @escaping (QrFrame) throws -> QrScan,
        release: @escaping () -> Void,
        post: @escaping (@escaping () -> Void) -> Void,
        onScan: @escaping (QrScan) -> Void
    ) {
        self.decode = decode
        self.release = release
        self.post = post
        self.onScan = onScan
    }

    var retired: Bool {
        lock.withLock { closed }
    }

    /** True when the frame was taken, false when dropped. */
    @discardableResult
    func offer(frame: QrFrame) -> Bool {
        let admitted: Bool = lock.withLock {
            if closed || latched || busy { return false }
            busy = true
            return true
        }
        if !admitted { return false }
        var scan: QrScan? = try? decode(frame)
        let releaseNow: Bool = lock.withLock {
            busy = false
            if closed { scan = nil }
            if case .decoded = scan { latched = true }
            let now = closed && !released
            if now { released = true }
            return now
        }
        if releaseNow { release() }
        guard let result = scan else { return true }
        post { [self] in
            if lock.withLock({ closed }) { return }
            onScan(result)
        }
        return true
    }

    func retire() {
        let releaseNow: Bool = lock.withLock {
            if closed { return false }
            closed = true
            let now = !busy && !released
            if now { released = true }
            return now
        }
        if releaseNow { release() }
    }
}

/** What the viewfinder shows about the stream: the ring and one notice. */
struct QrScanState: Equatable {
    var fraction: Float = 0
    var partsSeen: Int = 0
    var partsExpected: Int = 0
    var notice: String? = nil

    func after(scan: QrScan) -> QrScanState {
        switch scan {
        case let .progress(partsSeen, partsExpected, fraction):
            return QrScanState(fraction: fraction, partsSeen: Int(partsSeen), partsExpected: Int(partsExpected), notice: nil)
        case .decoded:
            var next = self
            next.fraction = 1
            next.notice = nil
            return next
        case let .rejected(reason):
            // The stream in progress is untouched by a stray code; only the notice changes.
            var next = self
            next.notice = reason
            return next
        }
    }
}
