import Foundation

private typealias Phase = ScanWorkPhase

let MAX_PROGRESS_REGIONS = 512
let PROGRESS_FRAME_MS: Int64 = 16
let PROGRESS_STAGE_MS: Int64 = 240
let MAX_PROGRESS_EVENTS = 8192
func progressClockMs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

struct ScanProgressException: Error, LocalizedError, Equatable {
    let message = "Scan updates were interrupted. Please try again."
    var errorDescription: String? { message }
}

extension ScanWorkPhase {
    /** Kotlin's `Phase.entries`, in stage order. */
    static let entries: [ScanWorkPhase] = [.preparing, .finding, .geometry, .reading, .checking, .packing]

    /** Kotlin's enum ordinal: the stage's place in `entries`. */
    var ordinal: Int {
        switch self {
        case .preparing: return 0
        case .finding: return 1
        case .geometry: return 2
        case .reading: return 3
        case .checking: return 4
        case .packing: return 5
        }
    }
}

struct PhotoFrame: Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
}

struct ProgressRegion: Equatable {
    let id: UInt32
    let corners: [Float]
    let state: ScanRegionState
}

enum ProgressOutcome: Equatable { case finished, failed }

/** Immutable snapshots only; no generated records, images, words or UI references. */
struct ScanProgressState: Equatable {
    var token: Int
    var sequence: UInt64 = 0
    var phase: ScanWorkPhase = .preparing
    var completed: UInt32 = 0
    var total: UInt32? = nil
    var frame: PhotoFrame? = nil
    /** The phrase card's corners once its marks established one; its fields are the regions. */
    var card: [Float]? = nil
    var regions: [UInt32: ProgressRegion] = [:]
    var seen: Set<UInt32> = []
    var retired: Set<UInt32> = []
    var finalIndices: [UInt32: UInt32] = [:]
    var overlaysDisabled: Bool = false
    var unavailable: Bool = false
    var outcome: ProgressOutcome? = nil
    var stages: Set<ScanWorkPhase> = []

    var fraction: Float? {
        if !unavailable && outcome == nil, let total, total > 0 { return Float(completed) / Float(total) }
        return nil
    }

    var label: String {
        if unavailable { return "Reading your photo" }
        if outcome == .failed { return "The photo could not be read" }
        if outcome != nil { return "Preparing review" }
        if phase == .preparing { return "Preparing to read" }
        if card != nil && phase.ordinal <= Phase.geometry.ordinal { return "Phrase card found" }
        if card != nil && phase == .reading { return "Reading the card's 12 fields" }
        switch phase {
        case .finding: return "Finding words"
        case .geometry: return "Fitting columns and boxes"
        case .reading: return "Reading words"
        case .checking: return "Checking readings"
        default: return "Preparing review"
        }
    }

    var countLabel: String? {
        guard !unavailable, outcome == nil, phase == .reading, let total else { return nil }
        if card != nil { return "\(completed) of \(total) fields read" }
        return total == 0 ? "No candidate regions to read" : "\(completed) of \(total) candidate regions read"
    }

    private func withoutOverlays() -> ScanProgressState {
        var next = self
        next.overlaysDisabled = true
        next.regions = [:]
        next.seen = []
        next.retired = []
        next.finalIndices = [:]
        return next
    }

    private func malformed() -> ScanProgressState {
        var next = withoutOverlays()
        next.unavailable = true
        next.total = nil
        return next
    }

    private func with(_ change: (inout ScanProgressState) -> Void) -> ScanProgressState {
        var next = self
        change(&next)
        return next
    }

    /** Validate every native delta; the UI replays the same ordered stream. */
    func reduce(event: ScanProgressEvent) -> ScanProgressState {
        if outcome != nil { return self } // Terminal state cannot be overwritten by a late delta.
        let next = with { $0.sequence = event.sequence }
        let update = event.update
        // Even fallback observation consumes terminal outcomes, but never navigates.
        if case .failed = update { return next.withoutOverlays().with { $0.outcome = .failed } }
        if event.sequence != sequence + 1 {
            var finished = false
            if case .finished = update { finished = true }
            return next.malformed().with { $0.outcome = finished ? .finished : nil }
        }
        if case let .finished(mappings) = update {
            if overlaysDisabled || mappings.count > MAX_PROGRESS_REGIONS {
                return next.withoutOverlays().with { $0.outcome = .finished }
            }
            var mapping: [UInt32: UInt32] = [:]
            for region in mappings { mapping[region.id] = region.wordIndex }
            if mapping.count != mappings.count || Set(mapping.values).count != mapping.count ||
                mapping.values.contains(where: { $0 >= UInt32(mapping.count) }) ||
                mapping.keys.contains(where: { !seen.contains($0) }) {
                return next.malformed().with { $0.outcome = .finished }
            }
            return next.with {
                $0.outcome = .finished
                $0.finalIndices = mapping
                $0.regions = regions.filter { mapping[$0.key] != nil && !retired.contains($0.key) }
            }
        }
        if unavailable { return next }
        switch update {
        case let .photo(width, height):
            // Kotlin's `toInt()` of an unsigned past Int.MAX_VALUE is negative, so refused.
            let limit = UInt32(Int32.max)
            if frame != nil || width == 0 || height == 0 || width > limit || height > limit { return next.malformed() }
            return next.with { $0.frame = PhotoFrame(width: Int(width), height: Int(height)) }
        case let .work(updatePhase, updateCompleted, updateTotal):
            if updatePhase.ordinal < phase.ordinal ||
                (updateTotal != nil && updateCompleted > updateTotal!) ||
                (updatePhase == phase && sequence != 0 && (updateTotal != total || updateCompleted < completed)) {
                return next.malformed()
            }
            return next.with {
                $0.phase = updatePhase
                $0.completed = updateCompleted
                $0.total = updateTotal
                $0.stages.insert(updatePhase)
            }
        case let .form(corners):
            if frame == nil || card != nil || !regions.isEmpty || corners.count != 8 ||
                corners.contains(where: { !$0.isFinite }) {
                return next.malformed()
            }
            return next.with { $0.card = corners }
        case let .region(region):
            return overlaysDisabled ? next : next.upsert(region)
        case let .replaced(region, parents):
            if overlaysDisabled { return next }
            if parents.isEmpty || parents.count > MAX_PROGRESS_REGIONS ||
                parents.contains(where: { regions[$0] == nil || retired.contains($0) }) ||
                Set(parents).count != parents.count || seen.contains(region.id) {
                return next.malformed()
            }
            return next.with {
                for parent in parents { $0.regions.removeValue(forKey: parent) }
                $0.retired.formUnion(parents)
            }.upsert(region)
        case let .removed(id):
            if overlaysDisabled { return next }
            if !seen.contains(id) { return next.malformed() }
            return next.with {
                $0.regions.removeValue(forKey: id)
                $0.retired.insert(id)
            }
        case .finished, .failed:
            return next // Both terminals were handled above.
        }
    }

    private func upsert(_ region: ScanRegion) -> ScanProgressState {
        if frame == nil || region.corners.count != 8 || region.corners.contains(where: { !$0.isFinite }) ||
            retired.contains(region.id) {
            return malformed()
        }
        if !seen.contains(region.id) && seen.count == MAX_PROGRESS_REGIONS { return withoutOverlays() }
        return with {
            $0.seen.insert(region.id)
            $0.regions[region.id] = ProgressRegion(id: region.id, corners: region.corners, state: region.state)
        }
    }
}

/**
 * Bounded lossless deltas, not a latest-only mailbox. Native never waits on drawing.
 * Every displayed snapshot needs a draw acknowledgement before the next one.
 * Cancellation clears the queue; malformed/overflowing streams cannot enter review.
 */
final class ScanProgressHandoff: ScanProgressObserver, @unchecked Sendable {
    let token: Int
    private let lock = NSLock()
    private var latest: ScanProgressState?
    private var visible: ScanProgressState?
    private var pending: [ScanProgressEvent] = []
    private var pendingStart = 0
    private var presentedAt: Int64?
    private var dwellMs = PROGRESS_STAGE_MS
    private var sealed = false
    private var overflow = false

    init(token: Int) {
        self.token = token
        latest = ScanProgressState(token: token)
        visible = latest
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private var pendingCount: Int { pending.count - pendingStart }

    func snapshot() -> ScanProgressState? { locked { latest } }

    func detach() {
        locked {
            latest = nil
            visible = nil
            pending.removeAll()
            pendingStart = 0
            presentedAt = nil
        }
    }

    func presented(sequence: UInt64, nowMs: Int64 = progressClockMs()) {
        locked {
            if visible?.sequence == sequence && presentedAt == nil { presentedAt = nowMs }
        }
    }

    func nextFrame(nowMs: Int64 = progressClockMs()) -> ScanProgressState? {
        locked { () -> ScanProgressState? in
            guard let current = visible else { return nil }
            guard let shown = presentedAt else { return current }
            if nowMs - shown < dwellMs || pendingCount == 0 { return current }
            let event = pending[pendingStart]
            pendingStart += 1
            if pendingStart == pending.count {
                pending.removeAll(keepingCapacity: true)
                pendingStart = 0
            }
            let next = current.reduce(event: event)
            dwellMs = next.phase != current.phase || next.outcome != nil ? PROGRESS_STAGE_MS : PROGRESS_FRAME_MS
            presentedAt = nil
            visible = next
            return next
        }
    }

    func sealSuccess() throws {
        try locked {
            guard let state = latest else { throw CancellationError() }
            if overflow || state.unavailable || state.overlaysDisabled || state.frame == nil ||
                state.outcome != .finished || state.stages != Set(Phase.entries) {
                throw ScanProgressException()
            }
            sealed = true
        }
    }

    func playbackComplete(nowMs: Int64 = progressClockMs()) -> Bool {
        locked { () -> Bool in
            guard sealed, pendingCount == 0, visible?.outcome == .finished, let shown = presentedAt else { return false }
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

    func onProgress(event: ScanProgressEvent) throws {
        try locked {
            guard let old = latest else { throw ProgressDeliveryError.Detached }
            if old.outcome != nil { return }
            if pendingCount == MAX_PROGRESS_EVENTS {
                overflow = true
                throw ProgressDeliveryError.Failed
            }
            // Generated Swift records and arrays are values: the event is already a private copy.
            latest = old.reduce(event: event)
            pending.append(event)
        }
    }
}

/** A monotone display estimate, never reported as native work counts or model confidence. */
final class ScanProgressMeter {
    private var phase: ScanWorkPhase = .preparing
    private var phaseAt: Int64
    private var value: Float = 0.01

    init(startMs: Int64) { phaseAt = startMs }

    func advance(state: ScanProgressState?, nowMs: Int64) -> Float {
        let next = state?.phase ?? .preparing
        if next != phase {
            phase = next
            phaseAt = nowMs
        }
        let bounds: [Float] = [0.01, 0.10, 0.22, 0.42, 0.80, 0.94, 0.99]
        let start = bounds[phase.ordinal]
        let end = bounds[phase.ordinal + 1]
        let elapsed = max(nowMs - phaseAt, 0)
        let estimate = Float(1.0 - exp(-Double(elapsed) / 10_000.0))
        let within = max(state?.fraction ?? 0, estimate * 0.95)
        value = max(value, start + (end - start) * within)
        if state?.outcome == .finished { value = 1 }
        return value
    }
}
