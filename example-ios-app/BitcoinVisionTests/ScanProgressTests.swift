import XCTest
@testable import BitcoinVision

private typealias Update = ScanProgressUpdate
private typealias State = ScanRegionState
private typealias Phase = ScanWorkPhase

private func box(_ id: UInt32, _ state: State = .read) -> ScanRegion {
    ScanRegion(id: id, corners: [10, 20, 100, 20, 100, 40, 10, 40], state: state)
}

private final class ProgressStream {
    let handoff: ScanProgressHandoff
    var sequence: UInt64 = 0

    init(_ token: Int = 1) { handoff = ScanProgressHandoff(token: token) }

    func send(_ update: Update) throws {
        sequence += 1
        try handoff.onProgress(event: ScanProgressEvent(sequence: sequence, update: update))
    }
    func state() -> ScanProgressState { handoff.snapshot()! }
    func photo() throws { try send(.photo(width: 640, height: 480)) }
    func region(_ id: UInt32, _ state: State = .found) throws { try send(.region(region: box(id, state))) }
}

final class ScanProgressTests: XCTestCase {
    func test_counts_precede_boxes_and_are_phase_local_not_whole_scan_completion() throws {
        let s = ProgressStream()
        try s.photo()
        try s.send(.work(phase: .reading, completed: 0, total: 2))
        XCTAssertTrue(s.state().regions.isEmpty)
        XCTAssertEqual(0, s.state().fraction)
        try s.region(0)
        try s.region(0, .read)
        try s.send(.work(phase: .reading, completed: 1, total: 2))
        XCTAssertEqual(0.5, s.state().fraction)
        XCTAssertEqual("1 of 2 candidate regions read", s.state().countLabel)
        try s.region(1, .read)
        try s.send(.work(phase: .reading, completed: 2, total: 2))
        XCTAssertEqual(1, s.state().fraction)
        XCTAssertNil(s.state().outcome)
        try s.send(.work(phase: .checking, completed: 0, total: nil))
        XCTAssertNil(s.state().fraction)
        XCTAssertEqual("Checking readings", s.state().label)
    }

    func test_a_found_card_names_itself_and_its_fields_and_a_page_never_does() throws {
        let card: [Float] = [5, 5, 200, 5, 200, 470, 5, 470]
        let s = ProgressStream()
        try s.photo()
        try s.send(.work(phase: .finding, completed: 0, total: nil))
        XCTAssertEqual("Finding words", s.state().label)
        try s.send(.form(corners: card))
        XCTAssertEqual(card, s.state().card)
        XCTAssertEqual("Phrase card found", s.state().label)
        try s.send(.work(phase: .geometry, completed: 0, total: 12))
        XCTAssertEqual("Phrase card found", s.state().label)
        try s.send(.work(phase: .reading, completed: 3, total: 12))
        XCTAssertEqual("Reading the card's 12 fields", s.state().label)
        XCTAssertEqual("3 of 12 fields read", s.state().countLabel)

        let page = ProgressStream()
        try page.photo()
        try page.send(.work(phase: .finding, completed: 0, total: nil))
        try page.send(.work(phase: .reading, completed: 0, total: 2))
        XCTAssertNil(page.state().card)
        XCTAssertEqual("Reading words", page.state().label)
    }

    func test_a_card_before_the_photo_or_after_its_fields_is_malformed() throws {
        let card: [Float] = [5, 5, 200, 5, 200, 470, 5, 470]
        let early = ProgressStream()
        try early.send(.form(corners: card))
        XCTAssertTrue(early.state().unavailable)
        let late = ProgressStream()
        try late.photo()
        try late.region(0)
        try late.send(.form(corners: card))
        XCTAssertTrue(late.state().unavailable)
    }

    func test_empty_reading_stage_never_divides_by_zero() throws {
        let s = ProgressStream()
        try s.send(.work(phase: .reading, completed: 0, total: 0))
        XCTAssertNil(s.state().fraction)
        XCTAssertEqual("No candidate regions to read", s.state().countLabel)
        try s.send(.finished(regions: []))
        XCTAssertEqual(.finished, s.state().outcome)
    }

    func test_accumulated_stream_preserves_replacements_removals_trims_and_terminal_mapping() throws {
        let s = ProgressStream()
        try s.photo()
        try s.region(0); try s.region(1); try s.region(2)
        try s.send(.replaced(region: box(3), parents: [0, 1]))
        try s.send(.removed(id: 2))
        var narrowed = box(3)
        narrowed.corners = [30, 20, 100, 20, 100, 40, 30, 40]
        try s.send(.region(region: narrowed))
        try s.send(.finished(regions: [ScanRegionMapping(id: 0, wordIndex: 0), ScanRegionMapping(id: 3, wordIndex: 1),
                                       ScanRegionMapping(id: 1, wordIndex: 2)]))
        // Validation sees the full ordered stream even before visual playback starts.
        let state = s.state()
        XCTAssertEqual([3], Set(state.regions.keys))
        XCTAssertEqual(narrowed.corners, state.regions[3]!.corners)
        XCTAssertEqual([0: 0, 3: 1, 1: 2], state.finalIndices)
        XCTAssertEqual([0, 1, 2], state.retired)
        try s.send(.region(region: box(0)))
        XCTAssertEqual(state, s.state())
    }

    func test_generated_mutable_records_cannot_change_a_published_snapshot() throws {
        let s = ProgressStream(); try s.photo()
        var points = box(0).corners
        var region = ScanRegion(id: 0, corners: points, state: .found)
        try s.send(.region(region: region))
        points[0] = 500
        region.corners = points
        region.state = .read
        XCTAssertEqual(10, s.state().regions[0]!.corners[0])
        XCTAssertEqual(.found, s.state().regions[0]!.state)
    }

    func test_overflow_bounds_ids_even_when_removed_and_keeps_counts_and_terminal() throws {
        let s = ProgressStream(); try s.photo()
        try s.send(.work(phase: .reading, completed: 0, total: 600))
        for id in 0...UInt32(MAX_PROGRESS_REGIONS) {
            try s.region(id)
            try s.send(.removed(id: id))
        }
        XCTAssertTrue(s.state().overlaysDisabled)
        XCTAssertFalse(s.state().unavailable)
        XCTAssertTrue(s.state().regions.isEmpty && s.state().seen.isEmpty && s.state().retired.isEmpty)
        try s.send(.work(phase: .reading, completed: 300, total: 600))
        XCTAssertEqual(0.5, s.state().fraction)
        try s.send(.finished(regions: (0...599).map { ScanRegionMapping(id: $0, wordIndex: $0) }))
        XCTAssertEqual(.finished, s.state().outcome)
        XCTAssertTrue(s.state().finalIndices.isEmpty)
    }

    func test_a_failed_attempt_clears_boxes_and_cannot_be_resurrected() throws {
        let s = ProgressStream(); try s.photo(); try s.region(0)
        try s.send(.failed)
        let failed = s.state()
        XCTAssertEqual(.failed, failed.outcome)
        XCTAssertTrue(failed.regions.isEmpty)
        try s.send(.finished(regions: []))
        XCTAssertEqual(failed, s.state())
    }

    func test_detach_rejects_late_events_and_a_new_attempt_has_its_own_sequence() throws {
        let old = ProgressStream(7); try old.photo(); try old.region(0)
        old.handoff.detach()
        let next = ProgressStream(9); try next.send(.work(phase: .finding, completed: 0, total: nil))
        XCTAssertThrowsError(try old.send(.region(region: box(0))), "detached callback accepted") { error in
            XCTAssertEqual(ProgressDeliveryError.Detached, error as? ProgressDeliveryError)
        }
        XCTAssertNil(old.handoff.snapshot())
        XCTAssertEqual(9, next.state().token)
        XCTAssertEqual(1, next.state().sequence)
        XCTAssertTrue(next.state().regions.isEmpty)
    }

    func test_detach_wins_against_an_in_flight_producer() throws {
        let s = ProgressStream(); try s.photo()
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            entered.signal()
            do {
                for _ in 0..<2_000 { try s.region(0, .reading) }
            } catch {
                XCTAssertEqual(ProgressDeliveryError.Detached, error as? ProgressDeliveryError)
            }
            finished.signal()
        }
        XCTAssertEqual(.success, entered.wait(timeout: .now() + 2))
        s.handoff.detach()
        XCTAssertEqual(.success, finished.wait(timeout: .now() + 5))
        XCTAssertNil(s.handoff.snapshot())
    }

    func test_broken_sequence_or_count_disables_inconsistent_progress_but_not_terminal() throws {
        let s = ProgressStream(); try s.photo(); try s.region(0)
        try s.handoff.onProgress(event: ScanProgressEvent(sequence: 50, update: .region(region: box(1))))
        XCTAssertTrue(s.state().unavailable)
        XCTAssertTrue(s.state().regions.isEmpty)
        try s.handoff.onProgress(event: ScanProgressEvent(sequence: 52, update: .finished(regions: [])))
        XCTAssertEqual(.finished, s.state().outcome)
        let changing = ProgressStream()
        try changing.send(.work(phase: .reading, completed: 1, total: 2))
        try changing.send(.work(phase: .reading, completed: 1, total: 3))
        XCTAssertTrue(changing.state().unavailable)
        XCTAssertNil(changing.state().fraction)
    }

    func test_geometry_revisions_do_not_reset_a_started_reading_counter() throws {
        let s = ProgressStream(); try s.photo()
        try s.send(.work(phase: .geometry, completed: 0, total: nil)); try s.region(0); try s.region(1)
        try s.send(.removed(id: 1))
        try s.send(.work(phase: .geometry, completed: 0, total: nil)); try s.region(0)
        try s.send(.work(phase: .reading, completed: 0, total: 1))
        try s.region(0, .read); try s.send(.work(phase: .reading, completed: 1, total: 1))
        XCTAssertFalse(s.state().unavailable)
        XCTAssertEqual([0], Set(s.state().regions.keys))
    }

    func test_fast_native_completion_must_replay_every_stage_and_box_before_review() throws {
        let s = ProgressStream(); try s.photo()
        for phase in Phase.entries {
            try s.send(.work(phase: phase, completed: 0, total: phase == .reading ? 1 : nil))
            if phase == .geometry { try s.region(0, .found) }
            if phase == .reading {
                try s.region(0, .reading); try s.region(0, .read)
                try s.send(.work(phase: phase, completed: 1, total: 1))
            }
        }
        try s.send(.finished(regions: [ScanRegionMapping(id: 0, wordIndex: 0)]))
        try s.handoff.sealSuccess()
        XCTAssertEqual(0, s.handoff.nextFrame(nowMs: 10_000)!.sequence) // No draw, no advancement.
        XCTAssertFalse(s.handoff.playbackComplete(nowMs: 10_000))
        var now: Int64 = 0
        var phases = Set<Phase>()
        var states = Set<State>()
        var visible = s.handoff.nextFrame(nowMs: now)!
        while visible.outcome == nil {
            phases.insert(visible.phase)
            if let region = visible.regions[0] { states.insert(region.state) }
            s.handoff.presented(sequence: visible.sequence, nowMs: now)
            now += PROGRESS_STAGE_MS
            visible = s.handoff.nextFrame(nowMs: now)!
        }
        XCTAssertEqual(Set(Phase.entries), phases)
        XCTAssertEqual([.found, .reading, .read], states)
        XCTAssertFalse(s.handoff.playbackComplete(nowMs: now)) // Finished must itself be drawn and held.
        s.handoff.presented(sequence: visible.sequence, nowMs: now)
        XCTAssertFalse(s.handoff.playbackComplete(nowMs: now + PROGRESS_STAGE_MS - 1))
        XCTAssertTrue(s.handoff.playbackComplete(nowMs: now + PROGRESS_STAGE_MS))
        s.handoff.detach()
        XCTAssertNil(s.handoff.nextFrame(nowMs: now))
    }

    func test_a_silent_or_incomplete_reader_cannot_open_review() throws {
        let finishedEarly = ProgressStream()
        try finishedEarly.photo()
        try finishedEarly.send(.finished(regions: []))
        for s in [ProgressStream(), finishedEarly] {
            XCTAssertThrowsError(try s.handoff.sealSuccess(), "missing stages accepted") { error in
                XCTAssertTrue(error is ScanProgressException)
            }
        }
    }

    func test_estimated_bar_moves_during_opaque_work_and_never_resets_or_finishes_early() {
        let meter = ScanProgressMeter(startMs: 0)
        var previous = meter.advance(state: nil, nowMs: 0)
        XCTAssertTrue(previous > 0)
        for phase in Phase.entries {
            let state = ScanProgressState(token: 1, phase: phase)
            let start = Int64(phase.ordinal) * 30_000
            let first = meter.advance(state: state, nowMs: start)
            let later = meter.advance(state: state, nowMs: start + 20_000)
            XCTAssertTrue(first >= previous)
            XCTAssertTrue(later > first && later < 1)
            previous = later
        }
        XCTAssertEqual(1, meter.advance(state: ScanProgressState(token: 1, outcome: .finished), nowMs: 200_000))
    }
}
