import SwiftUI
import XCTest
@testable import BitcoinVision

final class ScanTraceTests: XCTestCase {
    func test_only_the_explicit_benchmark_build_delivers_numeric_events() {
        var calls = 0
        defer { ScanTrace.sink = nil }
        ScanTrace.sink = { _ in calls += 1; return true }
        ScanTrace.mark("test")
        XCTAssertEqual(SCAN_BENCHMARK ? 1 : 0, calls)
    }

    func test_ordinary_builds_do_not_add_a_drawing_modifier() {
        if !SCAN_BENCHMARK {
            let traced = Text("review").traceReviewFrame()
            XCTAssertTrue(type(of: traced) == Text.self)
            XCTAssertEqual("com.bitcoinvision.example", Bundle(for: SheetViewModel.self).bundleIdentifier)
        }
    }
}
