import SwiftUI

/** Kotlin's `BuildConfig.SCAN_BENCHMARK`: the fixture benchmark build is Android-only. */
let SCAN_BENCHMARK = false

/**
 * Optional numeric event sink for the separate fixture benchmark. Normal
 * builds do not call a sink, read a clock, or add a draw modifier. The sink
 * returns true only for its first observation of a marker.
 */
enum ScanTrace {
    nonisolated(unsafe) static var sink: ((String) -> Bool)?

    static func mark(_ name: String) {
        if SCAN_BENCHMARK { _ = sink?(name) }
    }
}

extension View {
    /**
     * Observe a frame that actually contains the review list. Only the
     * benchmark build would trace it, and there is no iOS benchmark build:
     * the view is returned unchanged.
     */
    func traceReviewFrame() -> Self { self }
}
