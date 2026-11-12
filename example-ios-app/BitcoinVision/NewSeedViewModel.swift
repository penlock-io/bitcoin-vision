import Foundation
import Observation

/** Owns a pending seed, never a wallet/key available to signing. */
@Observable @MainActor
final class NewSeedViewModel {
    private let backup = NewSeedBackup()
    @ObservationIgnored var reader: PhraseReader = NativePhraseReader()
    @ObservationIgnored var preparer: PhotoPreparer = PhotoPreparer { try resolvePhoto(photo: $0) }
    @ObservationIgnored var generate: () throws -> [String] = { try newPhrase() }
    @ObservationIgnored private let scanning = SerialLock()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var progressWorker: Task<Void, Never>?
    @ObservationIgnored private var handoff: ScanProgressHandoff?
    private(set) var progress: ScanProgressState?

    var stage: NewSeedStage { backup.stage }
    var words: [String] { backup.words }
    var message: String? { backup.message }
    var order: Order? { backup.order }
    var availableOrders: Set<Order> { backup.availableOrders }
    var readWords: [String] { backup.readWords }
    var entries: [Entry] { backup.entries }
    var acknowledged: Set<Int> { backup.acknowledged }
    var frame: PhotoFrame? { backup.frame }
    var photo: ResolvedPhoto? {
        switch backup.attempt {
        case let .processing(_, photo): return photo
        case let .done(_, photo, _): return photo
        case let .failed(_, photo, _, _): return photo
        default: return nil
        }
    }
    var capturing: Bool {
        if case .capturing = backup.attempt { return true }
        return false
    }

    init() {}

    func start() -> Bool {
        cancel()
        do {
            let words = try generate()
            guard words.count == 12 else { return false }
            backup.start(words: words)
            return true
        } catch {
            return false
        }
    }

    private func stopWork() {
        handoff?.detach()
        handoff = nil
        progressWorker?.cancel()
        progressWorker = nil
        progress = nil
        worker?.cancel()
        worker = nil
    }

    func cancel() { stopWork(); backup.cancel() }
    func retake() { stopWork(); backup.retake() }
    func showWords() { stopWork(); backup.showWords() }
    func begin() -> Int { backup.begin() }
    func chooseOrder(order: Order) { backup.chooseOrder(value: order) }
    func acknowledge(position: Int) { backup.acknowledge(position: position) }
    func progressPresented(token: Int, sequence: UInt64) {
        if let handoff, handoff.token == token { handoff.presented(sequence: sequence) }
    }
    func consumeVerified() -> [String]? { backup.consumeVerified() }

    func deliver(token: Int, photo: PhotoInput?) {
        guard backup.deliver(token: token, photo: photo), let photo else { return }
        let events = ScanProgressHandoff(token: token)
        handoff = events
        progress = events.nextFrame()
        progressWorker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.progress = events.nextFrame()
                try? await Task.sleep(nanoseconds: UInt64(PROGRESS_FRAME_MS) * 1_000_000)
            }
        }
        let preparer = self.preparer
        let reader = self.reader
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                events.detach()
                if self.handoff === events {
                    self.worker = nil
                    self.progressWorker?.cancel()
                    self.progressWorker = nil
                    self.handoff = nil
                    self.progress = nil
                }
            }
            do {
                let resolved = try await preparePhoto(photo, with: preparer)
                try Task.checkCancellation()
                if !self.backup.prepared(token: token, photo: resolved) { return }
                await self.scanning.lock()
                let result = await Task.detached { () -> Result<PhraseScan, Error> in
                    Result { try reader.scan(photo: resolved, observer: events) }
                }.value
                self.scanning.unlock()
                let scan = try result.get()
                try Task.checkCancellation()
                try await events.awaitPlayback()
                try Task.checkCancellation()
                self.backup.finish(token: token, result: BackupReading.from(scan: scan))
            } catch is CancellationError {
                return
            } catch {
                // Never surface/log an error payload containing OCR text or seed words.
                if !Task.isCancelled { self.backup.fail(token: token) }
            }
        }
    }
}
