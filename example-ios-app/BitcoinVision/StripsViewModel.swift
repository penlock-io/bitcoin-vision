import Foundation
import Observation

enum Capture {
    case reading

    case found(strips: [StripReading])

    case failed(message: String)
}

enum StripScan {
    case idle

    /// The wizard: step one while nothing is held, step two after.
    case scanning(held: StripReading?)

    /// The phrase two shares recovered, for whoever asked for it.
    case recovered(words: [String], first: UInt8, second: UInt8)
}

/** What reads a photographed strip into its cells. */
protocol StripReader: Sendable {
    func read(photo: ResolvedPhoto) throws -> [StripReading]
    func readWithProgress(photo: ResolvedPhoto, observer: StripProgressObserver) throws -> [StripReading]
    var requiresProgress: Bool { get }
}

extension StripReader {
    func readWithProgress(photo: ResolvedPhoto, observer: StripProgressObserver) throws -> [StripReading] {
        try read(photo: photo)
    }
    var requiresProgress: Bool { false }
}

/** The bundled cell model's scanner, loaded once on first use. */
final class NativeStripReader: StripReader, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Scanner?

    private func scanner() throws -> Scanner {
        try lock.withLock {
            if let loaded { return loaded }
            guard let url = Bundle.main.url(forResource: "cell-reference", withExtension: "onnx", subdirectory: "models")
            else { throw VisionError.Model(detail: "The strip model is missing from the app.") }
            let made = try Scanner(model: try Data(contentsOf: url))
            loaded = made
            return made
        }
    }

    var requiresProgress: Bool { true }

    func read(photo: ResolvedPhoto) throws -> [StripReading] {
        try scanner().readOriented(photo: photo.source.copyBytes(), orientation: UInt8(photo.orientation))
    }

    func readWithProgress(photo: ResolvedPhoto, observer: StripProgressObserver) throws -> [StripReading] {
        try scanner().readOrientedWithProgress(photo: photo.source.copyBytes(), orientation: UInt8(photo.orientation),
                                               observer: observer)
    }
}

/** The generated error's own words, as Kotlin's message without its `detail=` prefix. */
func stripVisionDetail(_ error: VisionError) -> String {
    switch error {
    case let .Photo(detail), let .Model(detail), let .Scan(detail), let .Qr(detail),
         let .Recover(detail), let .Phrase(detail), let .Psbt(detail):
        return detail
    }
}

/** A coroutine Mutex for main-actor work: one holder at a time, the rest wait in order. */
@MainActor
final class SerialLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init() {}

    func lock() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// The strip wizard: photograph two share strips and recover the
/// phrase they hold. What happens to the phrase is the caller's:
/// loading the key, or checking a backup against it.
@Observable @MainActor
final class StripsViewModel {
    /** The reader every attempt goes through; a test puts a slower or a failing one here. */
    @ObservationIgnored var reader: StripReader = NativeStripReader()

    /** The photographs taken, one current at a time. */
    let attempts = Attempts<[StripReading]>()
    @ObservationIgnored var preparer: PhotoPreparer = PhotoPreparer { try resolvePhoto(photo: $0) }
    @ObservationIgnored private let scanning = SerialLock()
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var progressJob: Task<Void, Never>?
    @ObservationIgnored private var handoff: StripProgressHandoff?
    private(set) var progress: StripProgressState?
    private(set) var reviewedStrip: StripReading?
    private(set) var heldPhoto: ResolvedPhoto?
    private(set) var editError: String?

    private(set) var scan: StripScan = .idle

    // Combining two shares can fail after both photographs succeeded;
    // that failure is the wizard's, not an attempt's.
    private var combined: Capture?

    init() {}

    private func stopProgress() {
        handoff?.detach(); handoff = nil
        progressJob?.cancel(); progressJob = nil
        progress = nil
    }

    private func startProgress(token: Int) -> StripProgressHandoff {
        stopProgress()
        let stream = StripProgressHandoff(token: token)
        handoff = stream
        progress = stream.snapshot()
        progressJob = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.handoff === stream, self.attempts.current?.token == token,
                      let frame = stream.nextFrame() else { break }
                if self.progress != frame { self.progress = frame }
                try? await Task.sleep(nanoseconds: UInt64(PROGRESS_FRAME_MS) * 1_000_000)
            }
        }
        return stream
    }

    func progressPresented(token: Int, sequence: UInt64) {
        if let handoff, handoff.token == token { handoff.presented(sequence: sequence) }
    }

    /** What the current photograph came to, or the last combination's failure. */
    var capture: Capture? {
        switch attempts.current {
        case .capturing, .preparing, .processing: return .reading
        case let .done(_, _, result): return .found(strips: result)
        case let .failed(_, _, message, _): return .failed(message: message)
        case nil: return combined
        }
    }

    func shareNumber(strip: StripReading) -> UInt8? {
        if case let .share(index) = strip.identity() { return index }
        return nil
    }

    func start() {
        stopProgress()
        scan = .scanning(held: nil)
        attempts.cancel()
        reading?.cancel()
        combined = nil
        reviewedStrip = nil
        heldPhoto = nil
        editError = nil
    }

    func cancel() {
        stopProgress()
        scan = .idle
        attempts.cancel()
        reading?.cancel()
        combined = nil
        reviewedStrip = nil
        heldPhoto = nil
    }

    /// Clears the wizard once its phrase has been taken.
    func finish() { cancel() }

    /** A new attempt at the shutter, named for the photo the camera will deliver. */
    func begin() -> Int {
        stopProgress()
        combined = nil
        reviewedStrip = nil
        editError = nil
        return attempts.begin()
    }

    /** The camera's photo for the attempt [token], read on a worker and
     * offered only if the attempt is still current when the read ends. */
    func deliver(token: Int, bytes: Data?) {
        if attempts.current?.token != token { return }
        deliverPhoto(token: token, photo: bytes.map { PhotoInput.fromFile(bytes: $0) })
    }

    func deliverPhoto(token: Int, photo: PhotoInput?) {
        guard attempts.deliverPhoto(token: token, photo: photo), let photo else { return }
        reading?.cancel()
        let stream = startProgress(token: token)
        let preparer = self.preparer
        let reader = self.reader
        reading = Task { @MainActor [weak self] in
            guard let self else { return }
            let strips: [StripReading]
            do {
                let resolved = try await preparePhoto(photo, with: preparer)
                if Task.isCancelled || !self.attempts.prepared(token: token, photo: resolved) { return }
                await self.scanning.lock()
                if Task.isCancelled || self.attempts.current?.token != token {
                    self.scanning.unlock()
                    return
                }
                let result = await Task.detached { () -> Result<[StripReading], Error> in
                    if photo.camera == nil { logPhotoInput(photo: photo) }
                    return Result { try reader.readWithProgress(photo: resolved, observer: stream) }
                }.value
                self.scanning.unlock()
                if Task.isCancelled { return }
                strips = try result.get()
            } catch let e as PhotoPreparationException {
                self.attempts.fail(token: token, message: e.message)
                return
            } catch let e as VisionError {
                self.attempts.fail(token: token, message: stripVisionDetail(e))
                return
            } catch let e as StripProgressError {
                self.attempts.fail(token: token, message: e.message)
                return
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    self.attempts.fail(token: token, message: "The strip scan did not complete.")
                }
                return
            }
            // A test reader may not implement progress; the native reader must.
            do {
                if reader.requiresProgress || stream.hasEvents() { try await stream.awaitPlayback() }
            } catch let e as StripProgressError {
                self.attempts.fail(token: token, message: e.message)
                return
            } catch {
                return
            }
            if Task.isCancelled { return }
            self.attempts.finish(token: token, result: strips)
        }
    }

    func savePhoto() async -> String? { await saveRawPhotoForDiagnosis(photo: attempts.photo) }
    func saveCanonicalPhoto() async -> String? { await saveCanonicalPhotoForDiagnosis(photo: attempts.resolvedPhoto) }

    func retake() {
        stopProgress()
        attempts.cancel()
        reading?.cancel()
        combined = nil
        reviewedStrip = nil
        editError = nil
    }

    private var held: StripReading? {
        if case let .scanning(held) = scan { return held }
        return nil
    }

    /// The share the wizard can take from a capture: the first share
    /// strip whose number is not already held.
    func usable(strips: [StripReading]) -> StripReading? {
        guard case let .scanning(heldStrip) = scan else { return nil }
        let held = heldStrip.flatMap { shareNumber(strip: $0) }
        return strips.first {
            let number = shareNumber(strip: $0)
            return number != nil && number != held
        }
    }

    /// Why a capture offered nothing usable.
    func refusal(strips: [StripReading]) -> String {
        let held = self.held.flatMap { shareNumber(strip: $0) }
        if strips.contains(where: { shareNumber(strip: $0) != nil && shareNumber(strip: $0) == held }) {
            return "That is share \(held.map(String.init) ?? "null") again — scan a different share."
        }
        if strips.contains(where: { $0.identity() == .seed }) {
            return "That is the seed strip — loading needs two share strips."
        }
        return "No share strip could be read in this photo."
    }

    /// Takes a share into the wizard. True when the second share
    /// completed it and the phrase is recovered.
    @discardableResult
    func use(strip: StripReading, paperChecked: Bool = false) -> Bool {
        guard case let .scanning(held) = scan else { return false }
        let effective = reviewedStrip ?? strip
        // A queued tap from the previous render must not authorize a
        // newly edited strip with an acknowledgement for its old reading.
        if effective !== strip {
            editError = "The strip changed. Review the latest reading before using it."
            return false
        }
        guard let held else {
            heldPhoto = attempts.resolvedPhoto
            attempts.cancel()
            stopProgress()
            reading?.cancel()
            scan = .scanning(held: effective)
            reviewedStrip = nil
            return false
        }
        let pair = combinedReview(strip: effective)
        if !shareUseAllowed(firstShareHeld: true, pair: pair, paperChecked: paperChecked) {
            editError = pair == nil ? "The shares cannot be combined. Review or retake them."
                : "Check every corrected or uncertain row against both paper strips first."
            return false
        }
        guard let first = shareNumber(strip: held), let second = shareNumber(strip: effective) else { return false }
        do {
            let words = try recover(a: held, b: effective)
            attempts.cancel()
            stopProgress()
            reading?.cancel()
            scan = .recovered(words: words, first: first, second: second)
            return true
        } catch let e as VisionError {
            editError = stripVisionDetail(e)
            return false
        } catch {
            editError = "The shares could not be combined."
            return false
        }
    }

    func currentStrip(strip: StripReading) -> StripReading { reviewedStrip ?? strip }

    func correctCell(strip: StripReading, row: Int, position: Int, text: String) {
        do {
            reviewedStrip = try currentStrip(strip: strip).withCell(row: UInt32(row), position: UInt32(position),
                                                                     text: text.uppercased())
            editError = nil
        } catch let e as VisionError { editError = stripVisionDetail(e) } catch {}
    }

    func resetCell(strip: StripReading, row: Int, position: Int) {
        do {
            reviewedStrip = try currentStrip(strip: strip).withoutCellEdit(row: UInt32(row), position: UInt32(position))
            editError = nil
        } catch let e as VisionError { editError = stripVisionDetail(e) } catch {}
    }

    func correctRow(strip: StripReading, row: Int, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.count != 6 || value.contains(where: { !"=#ABCDEFGHIJKLMNOPQRSTUVWXYZ-".contains($0) }) {
            editError = "Enter exactly six worksheet symbols."
            return
        }
        do {
            var next = currentStrip(strip: strip)
            for (index, char) in value.enumerated() {
                next = try next.withCell(row: UInt32(row), position: UInt32(index), text: String(char))
            }
            reviewedStrip = next
            editError = nil
        } catch let e as VisionError { editError = stripVisionDetail(e) } catch {}
    }

    func combinedReview(strip: StripReading) -> CombinedStripReview? {
        guard let held else { return nil }
        return try? reviewCombinedStrips(a: held, b: currentStrip(strip: strip))
    }
}
