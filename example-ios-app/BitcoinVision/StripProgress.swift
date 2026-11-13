import Foundation

private typealias Phase = StripWorkPhase

extension StripWorkPhase {
    /** Kotlin's `Phase.entries`, in stage order. */
    static let entries: [StripWorkPhase] = [.admitting, .locating, .identifying, .reading, .packing]

    /** Kotlin's enum ordinal: the stage's place in `entries`. */
    var ordinal: Int {
        switch self {
        case .admitting: return 0
        case .locating: return 1
        case .identifying: return 2
        case .reading: return 3
        case .packing: return 4
        }
    }
}

/** A failed `require`: Kotlin's IllegalArgumentException for strip progress. */
struct StripProgressError: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String = "Failed requirement.") { self.message = message }
    var errorDescription: String? { message }
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String = "Failed requirement.") throws {
    if !condition { throw StripProgressError(message()) }
}

struct StripProgressRegion: Equatable {
    let corners: [Float]
    let read: Bool
}

struct StripProgressState: Equatable {
    let token: Int
    var sequence: UInt64 = 0
    var phase: StripWorkPhase = .admitting
    var frame: PhotoFrame? = nil
    var regions: [UInt32: StripProgressRegion] = [:]
    var completed: UInt32 = 0
    var total: UInt32? = nil
    var stages: Set<StripWorkPhase> = []
    var finished: Bool = false
    var failed: Bool = false

    var label: String {
        switch phase {
        case .admitting: return "Preparing photo"
        case .locating: return "Finding strips"
        case .identifying: return "Reading strip numbers"
        case .reading: return "Reading cells"
        case .packing: return "Preparing review"
        }
    }

    func reduce(event: StripProgressEvent) throws -> StripProgressState {
        try require(!finished && !failed && event.sequence == sequence + 1, "Strip progress is out of order")
        var next = self
        next.sequence = event.sequence
        switch event.update {
        case let .photo(width, height):
            try require(frame == nil && width > 0 && height > 0)
            next.frame = PhotoFrame(width: Int(width), height: Int(height))
        case let .work(updatePhase, updateCompleted, updateTotal):
            try require(updatePhase.ordinal >= phase.ordinal &&
                (updateTotal == nil || updateCompleted <= updateTotal!) &&
                (updatePhase != phase || (updateTotal == total && updateCompleted >= completed)))
            next.phase = updatePhase
            next.completed = updateCompleted
            next.total = updateTotal
            next.stages.insert(updatePhase)
        case let .region(id, corners, read):
            try require(frame != nil && corners.count == 8 && corners.allSatisfy(\.isFinite) &&
                (regions[id] != nil || regions.count < Int(MAX_PROGRESS_REGIONS)))
            next.regions[id] = StripProgressRegion(corners: corners.map { Float($0) }, read: read)
        case let .replaced(id, corners, read, parents):
            try require(frame != nil && corners.count == 8 && corners.allSatisfy(\.isFinite) &&
                !parents.isEmpty && parents.allSatisfy { regions[$0] != nil } &&
                Set(parents).count == parents.count && regions[id] == nil)
            for parent in parents { next.regions.removeValue(forKey: parent) }
            next.regions[id] = StripProgressRegion(corners: corners.map { Float($0) }, read: read)
        case let .removed(id):
            try require(regions[id] != nil)
            next.regions.removeValue(forKey: id)
        case .finished:
            next.finished = true
        case .failed, .cancelled:
            next.failed = true
        }
        return next
    }
}

/** Bounded, ordered playback. A frame is not retired until SwiftUI drew it. */
final class StripProgressHandoff: StripProgressObserver, @unchecked Sendable {
    let token: Int
    private let lock = NSLock()
    private var latest: StripProgressState?
    private var visible: StripProgressState?
    private var pending: [StripProgressEvent] = []
    private var presentedAt: Int64?
    private var dwellMs = Int64(PROGRESS_STAGE_MS)
    private var sealed = false

    init(token: Int) {
        self.token = token
        latest = StripProgressState(token: token)
        visible = latest
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func detach() { locked { latest = nil; visible = nil; pending.removeAll() } }
    func snapshot() -> StripProgressState? { locked { visible } }
    func hasEvents() -> Bool { locked { latest?.sequence != 0 } }

    func presented(sequence: UInt64, nowMs: Int64 = Int64(progressClockMs())) {
        locked {
            if visible?.sequence == sequence && presentedAt == nil { presentedAt = nowMs }
        }
    }

    func nextFrame(nowMs: Int64 = Int64(progressClockMs())) -> StripProgressState? {
        locked { () -> StripProgressState? in
            guard let current = visible else { return nil }
            guard let shown = presentedAt else { return current }
            if nowMs - shown < dwellMs || pending.isEmpty { return current }
            // Every pending event already reduced onto `latest`; replaying it cannot fail.
            guard let next = try? current.reduce(event: pending.removeFirst()) else {
                pending.removeAll()
                return current
            }
            visible = next
            presentedAt = nil
            dwellMs = next.phase != current.phase || next.finished
                ? Int64(PROGRESS_STAGE_MS) : Int64(PROGRESS_FRAME_MS)
            return next
        }
    }

    func sealSuccess() throws {
        try locked {
            guard let end = latest else { throw CancellationError() }
            try require(end.finished && !end.failed && end.frame != nil && end.stages == Set(Phase.entries),
                        "The strip scanner did not complete its stages")
            sealed = true
        }
    }

    func playbackComplete(nowMs: Int64 = Int64(progressClockMs())) -> Bool {
        locked { () -> Bool in
            guard sealed, pending.isEmpty, visible?.finished == true, let shown = presentedAt else { return false }
            return nowMs - shown >= dwellMs
        }
    }

    func awaitPlayback() async throws {
        try sealSuccess()
        while !playbackComplete() {
            if snapshot() == nil { throw CancellationError() }
            try await Task.sleep(nanoseconds: UInt64(PROGRESS_FRAME_MS) * 1_000_000)
        }
    }

    func onProgress(event: StripProgressEvent) throws {
        try locked {
            guard let old = latest else { throw ProgressDeliveryError.Detached }
            if pending.count >= Int(MAX_PROGRESS_EVENTS) { throw ProgressDeliveryError.Failed }
            // Swift records and arrays are values: the event is already a private copy.
            do { latest = try old.reduce(event: event) } catch {
                throw ProgressDeliveryError.Failed
            }
            pending.append(event)
        }
    }
}
