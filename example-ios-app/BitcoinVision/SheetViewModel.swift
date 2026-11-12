import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
private let debugBuild = true
#else
private let debugBuild = false
#endif

private enum Picked {
    case photo(bytes: Data)

    case refused(message: String)
}

enum SheetStage: Equatable {
    case idle

    case scanning

    case reviewing
}

/** What reads a photographed page into words. */
protocol PhraseReader {
    /** A successful scan must emit every stage and its terminal mapping. No silent overload. */
    func scan(photo: ResolvedPhoto, observer: ScanProgressObserver) throws -> PhraseScan
    /** Explicit diagnostic attempt; legacy/test readers report no recorded files. */
    func scanDiagnosed(photo: ResolvedPhoto, observer: ScanProgressObserver) throws -> DiagnosedScan
}

extension PhraseReader {
    func scanDiagnosed(photo: ResolvedPhoto, observer: ScanProgressObserver) throws -> DiagnosedScan {
        DiagnosedScan(scan: try scan(photo: photo, observer: observer), files: [])
    }
}

/** One shared native pipeline and asset set for recovery and generated backups. */
final class NativePhraseReader: PhraseReader, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: PhraseScanner?

    init() {}

    private func scanner() throws -> PhraseScanner {
        try lock.withLock {
            if let loaded { return loaded }
            ScanTrace.mark("asset_load_start")
            func asset(_ name: String, _ ext: String) throws -> Data {
                guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "models") else {
                    throw VisionError.Model(detail: "The \(name).\(ext) model is missing from the app.")
                }
                return try Data(contentsOf: url)
            }
            let detector = try asset("word-detector", "onnx")
            let model = try asset("word-reference", "onnx")
            let calibration = String(decoding: try asset("word-reference", "calibration"), as: UTF8.self)
            let recogniser = try asset("text-recogniser", "onnx")
            let dictionary = String(decoding: try asset("text-recogniser.dict", "txt"), as: UTF8.self)
            ScanTrace.mark("asset_load_end")
            ScanTrace.mark("constructor_ffi_start")
            let made = try PhraseScanner(detector: detector, model: model, calibration: calibration,
                                         recogniser: recogniser, dictionary: dictionary)
            ScanTrace.mark("constructor_ffi_end")
            loaded = made
            return made
        }
    }

    func scan(photo: ResolvedPhoto, observer: ScanProgressObserver) throws -> PhraseScan {
        let ready = try scanner()
        ScanTrace.mark("scan_ffi_start")
        defer { ScanTrace.mark("scan_ffi_end") }
        return try ready.scanWithPhotoUpAndProgress(photo: photo.source.copyBytes(), orientation: UInt8(photo.orientation),
                                                     photoUp: photo.photoUp, observer: observer)
    }

    func scanDiagnosed(photo: ResolvedPhoto, observer: ScanProgressObserver) throws -> DiagnosedScan {
        let ready = try scanner()
        ScanTrace.mark("scan_ffi_start")
        defer { ScanTrace.mark("scan_ffi_end") }
        return try ready.scanWithPhotoUpAndDiagnostics(photo: photo.source.copyBytes(),
                                                        orientation: UInt8(photo.orientation),
                                                        photoUp: photo.photoUp, observer: observer)
    }
}

/** Kotlin's coroutine `Mutex` held across suspensions on Main: one holder at a time, the rest wait in order. */
@MainActor
private final class ScannerTurn {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
        defer {
            if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/**
 * The scanner reads JPEG, PNG or WebP. A library photo in another encoding
 * (HEIC, mostly) is re-encoded as JPEG with its metadata, EXIF orientation
 * included, and its pixels unturned; anything ImageIO cannot open is passed
 * on as it is, for the preparation step to refuse in its own words.
 */
private func scannerReadable(_ bytes: Data) -> Data {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let type = CGImageSourceGetType(source) as String?,
          ![UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier].contains(type)
    else { return bytes }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
    else { return bytes }
    CGImageDestinationAddImageFromSource(destination, source, 0,
                                         [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? out as Data : bytes
}

/** The generated error's own words: Kotlin's message without its `detail=` prefix. */
private func detail(_ error: VisionError) -> String {
    switch error {
    case let .Photo(detail), let .Model(detail), let .Scan(detail), let .Qr(detail),
         let .Recover(detail), let .Phrase(detail), let .Psbt(detail):
        return detail
    }
}

/** User-editable recovery review; generated backups never consume this draft. */
@Observable @MainActor
final class SheetViewModel {
    /** Shared native reader also used by generated-seed photo verification. */
    @ObservationIgnored var reader: PhraseReader = NativePhraseReader()

    /** Debug-only, one-shot opt-in. Ordinary scans, including debug scans, stay lean. */
    private(set) var traceNextScan = false
    @ObservationIgnored private var tracedAttempt: Int?
    @ObservationIgnored private var savedDiagnosis: SavedScanDiagnosis?

    func toggleDecisionTrace() {
        if debugBuild && !SCAN_BENCHMARK && attempts.current == nil {
            traceNextScan.toggle()
        }
    }

    /** The photographs taken, one current at a time. */
    let attempts = Attempts<PhraseScan>()
    @ObservationIgnored var preparer: PhotoPreparer = PhotoPreparer { try resolvePhoto(photo: $0) }

    // The scanner is one object reading one photo at a time; a retake
    // while it reads waits its turn rather than running beside it.
    @ObservationIgnored private let scanning = ScannerTurn()

    // The read of the current attempt, and no other: an attempt
    // cancelled or replaced takes its read with it, whether the read
    // is waiting its turn or under way. A read under way in native
    // code cannot be interrupted; it holds the scanner until it
    // returns, and returns into nothing.
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var progressJob: Task<Void, Never>?
    @ObservationIgnored private var progressHandoff: ScanProgressHandoff?
    private(set) var progress: ScanProgressState?

    init() {}

    private func stopProgress() {
        progressHandoff?.detach()
        progressHandoff = nil
        progressJob?.cancel()
        progressJob = nil
        progress = nil
    }

    private func startProgress(token: Int) -> ScanProgressHandoff {
        stopProgress()
        let handoff = ScanProgressHandoff(token: token)
        progressHandoff = handoff
        progress = handoff.snapshot()
        progressJob = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.progressHandoff === handoff, self.attempts.current?.token == token,
                      let latest = handoff.nextFrame() else { break }
                if self.progress != latest { self.progress = latest }
                try? await Task.sleep(nanoseconds: UInt64(PROGRESS_FRAME_MS) * 1_000_000)
            }
        }
        return handoff
    }

    func progressPresented(token: Int, sequence: UInt64) {
        if let handoff = progressHandoff, handoff.token == token { handoff.presented(sequence: sequence) }
    }

    private(set) var stage: SheetStage = .idle
    private(set) var photo: ResolvedPhoto?
    private(set) var scan: PhraseScan?
    private(set) var draft: PhraseDraft?

    /** Set once a read has produced words to review; the scan screen takes the navigation and clears it. */
    var reviewed = false

    /// The box the review is looking at, drawn heavier on the photo.
    var highlighted: Int?

    /** The current attempt's photo and capture metadata, whatever the read made of them. */
    var capture: PhotoInput? { attempts.photo }

    func start() {
        forget()
        stage = .scanning
    }

    func forget() {
        traceNextScan = false
        tracedAttempt = nil
        savedDiagnosis = nil
        stopProgress()
        attempts.cancel()
        reading?.cancel()
        stage = .idle
        photo = nil
        scan = nil
        draft = nil
        highlighted = nil
        reviewed = false
    }

    /** A new attempt at the shutter, named for the photo the camera will deliver. */
    @discardableResult
    func begin() -> Int {
        stopProgress()
        reading?.cancel()
        savedDiagnosis = nil
        let token = attempts.begin()
        tracedAttempt = debugBuild && traceNextScan ? token : nil
        traceNextScan = false
        return token
    }

    /**
     * The camera's photo for the attempt [token]: read on a worker,
     * and its words offered for review only if the attempt is still
     * the current one when the read ends.
     */
    func deliver(token: Int, bytes: Data?) {
        ScanTrace.mark("deliver_entry")
        if attempts.current?.token != token { return }
        readPhoto(token: token, photo: bytes.map { PhotoInput.fromFile(bytes: $0) })
    }

    func deliverPhoto(token: Int, photo: PhotoInput?) {
        ScanTrace.mark("deliver_entry")
        readPhoto(token: token, photo: photo)
    }

    /**
     * A photo the person picked out of their own library. It is loaded
     * off Main and bounded: the library can be in the cloud, slow, or
     * gone by the time it is read, and what it hands back is not
     * necessarily a photograph of a page.
     */
    func deliverDocument(item: PhotosPickerItem) {
        let token = begin()
        Task { @MainActor in
            let picked = await Self.open(item)
            switch picked {
            case let .refused(message): attempts.missing(token: token, message: message)
            case let .photo(bytes): deliver(token: token, bytes: bytes)
            }
        }
    }

    private nonisolated static func open(_ item: PhotosPickerItem) async -> Picked {
        let unopened = Picked.refused(message: "That file could not be opened. Choose another.")
        let data: Data
        do {
            guard let loaded = try await item.loadTransferable(type: Data.self) else { return unopened }
            data = loaded
        } catch {
            return unopened
        }
        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }
        guard let bytes = readAtMost(input: stream) else {
            return .refused(message: "That file is too large to be a photo of a page.")
        }
        if bytes.isEmpty { return .refused(message: "That file is empty. Choose another.") }
        return .photo(bytes: scannerReadable(bytes))
    }

    private func readPhoto(token: Int, photo: PhotoInput?) {
        guard attempts.deliverPhoto(token: token, photo: photo), let photo else { return }
        ScanTrace.mark("delivered")
        reading?.cancel()
        let handoff = startProgress(token: token)
        let recordDecisions = tracedAttempt == token
        let preparer = self.preparer
        let reader = self.reader
        reading = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // An old worker returning after retake must not clear the new attempt.
                handoff.detach()
                if self.progressHandoff === handoff { self.stopProgress() }
            }
            let result: DiagnosedScan
            do {
                ScanTrace.mark("orientation_start")
                let resolved = try await preparePhoto(photo, with: preparer)
                if Task.isCancelled || !self.attempts.prepared(token: token, photo: resolved) { return }
                ScanTrace.mark("orientation_end")
                let read: DiagnosedScan? = try await self.scanning.withLock {
                    if Task.isCancelled || self.attempts.current?.token != token { return nil }
                    return try await Task.detached(priority: .userInitiated) { () throws -> DiagnosedScan in
                        ScanTrace.mark("worker_start")
                        if photo.camera == nil { logPhotoInput(photo: photo) }
                        defer { ScanTrace.mark("worker_end") }
                        return recordDecisions
                            ? try reader.scanDiagnosed(photo: resolved, observer: handoff)
                            : DiagnosedScan(scan: try reader.scan(photo: resolved, observer: handoff), files: [])
                    }.value
                }
                guard let read, !Task.isCancelled else { return }
                result = read
            } catch let e as PhotoPreparationException {
                self.attempts.fail(token: token, message: e.message)
                return
            } catch let e as VisionError {
                self.attempts.fail(token: token, message: detail(e))
                return
            } catch {
                if !Task.isCancelled { self.attempts.fail(token: token, message: "The photo could not be read.") }
                return
            }
            ScanTrace.mark("result_received")
            do {
                try await handoff.awaitPlayback()
            } catch let e as ScanProgressException {
                self.attempts.fail(token: token, message: e.message)
                return
            } catch {
                return // Detached or cancelled: the attempt went with it.
            }
            if Task.isCancelled { return }
            if self.attempts.finish(token: token, result: result.scan) {
                self.photo = self.attempts.resolvedPhoto
                self.scan = result.scan
                self.savedDiagnosis = self.attempts.resolvedPhoto.flatMap { prepared in
                    result.files.isEmpty ? nil : SavedScanDiagnosis(photo: prepared, result: result)
                }
                ScanTrace.mark("draft_start")
                self.draft = self.draftOf(result: result.scan)
                ScanTrace.mark("draft_end")
                self.stage = .reviewing
                self.reviewed = true
                ScanTrace.mark("review_ready")
            }
        }
    }

    private func draftOf(result: PhraseScan) -> PhraseDraft {
        let numbers: Numbers
        switch result.numbering {
        case let .held(count, missing, outOfPlace, unresolved):
            numbers = .held(count: Int(count), missing: missing.map { Int($0) }, outOfPlace: outOfPlace.map { Int($0) },
                            unresolved: unresolved.count)
        case let .inconsistent(detail):
            numbers = .inconsistent(detail: detail)
        case .none:
            numbers = .none
        }
        let order: Order
        switch result.initialOrder {
        case .numbers: order = .numbers
        case .rows: order = .rows
        case .columns: order = .columns
        }
        return PhraseDraft(
            boxes: result.words.map { $0.reviewSource() },
            columns: result.columns.map { Int($0) },
            rows: result.rows.map { Int($0) },
            order: order,
            byNumber: result.numbered.map { Int($0) },
            numbers: numbers,
            listNumbered: result.listNumbered,
            orderRequiresReview: result.orderRequiresReview
        )
    }

    /** Drops the current attempt, read or unread, and returns to the camera. */
    func retake() {
        tracedAttempt = nil
        savedDiagnosis = nil
        stopProgress()
        attempts.cancel()
        reading?.cancel()
    }

    /**
     * Explicitly exports raw bytes/metadata and, if recorded for this capture,
     * native decisions/crops off Main. Unavailable in a release build.
     */
    func savePhoto() async -> String? { await saveRawPhotoForDiagnosis(photo: capture, diagnosis: savedDiagnosis) }
    func saveCanonicalPhoto() async -> String? { await saveCanonicalPhotoForDiagnosis(photo: attempts.resolvedPhoto) }

    func rescan() {
        tracedAttempt = nil
        savedDiagnosis = nil
        stopProgress()
        attempts.cancel()
        reading?.cancel()
        stage = .scanning
        photo = nil
        scan = nil
        draft = nil
        highlighted = nil
        reviewed = false
    }

    /// Whether the phrase fits a strip and passes the checksum.
    func passes() -> Bool {
        guard let draft else { return false }
        return draft.words.count == WORKSHEET_WORDS && checksumPasses(words: draft.words)
    }

    func status() -> String {
        guard let draft else { return "" }
        if passes() { return "Checksum passes" }
        if draft.words.count == WORKSHEET_WORDS { return "At least one word is wrong" }
        return phraseStatus(count: draft.words.count, passes: false, numbers: draft.numbers)
    }

    func change(id: Int, word: String) {
        draft = draft?.change(id: id, word: word)
    }

    func insert(at: Int, word: String, number: Int? = nil) {
        draft = draft?.insert(at: at, word: word, number: number)
    }

    func remove(id: Int) {
        draft = draft?.remove(id: id)
    }

    func restore(id: Int) {
        draft = draft?.restore(id: id)
    }

    func reorder(order: Order) {
        draft = draft?.reorder(order: order)
    }

    func check(id: Int, on: Bool) {
        draft = draft?.check(id: id, on: on)
    }

    /// Only a complete phrase with a passing checksum can leave recovery review.
    func confirmed() -> [String]? {
        guard let draft, passes() else { return nil }
        return draft.words
    }
}
