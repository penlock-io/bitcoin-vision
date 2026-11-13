import Foundation
import Observation

enum NewSeedStage { case idle, writing, camera, reading, review, verified }

/** Immutable, blind scan selections; never a user-editable PhraseDraft. */
final class BackupReading {
    let sequences: [Order: [String]]
    let initial: Order
    let requiresOrderReview: Bool
    let entries: [Order: [Entry]]
    let frame: PhotoFrame?

    init(
        sequences: [Order: [String]],
        initial: Order,
        requiresOrderReview: Bool,
        entries: [Order: [Entry]] = [:],
        frame: PhotoFrame? = nil
    ) {
        self.sequences = sequences
        self.initial = initial
        self.requiresOrderReview = requiresOrderReview
        self.entries = entries
        self.frame = frame
    }

    static func from(scan: PhraseScan) -> BackupReading {
        func words(_ indices: [UInt32]) -> [String] {
            indices.map { scan.words[Int($0)] }.filter { !$0.stray }.map(\.read)
        }
        var orders: [Order: [String]] = [.columns: words(scan.columns), .rows: words(scan.rows)]
        if case .held = scan.numbering { orders[.numbers] = words(scan.numbered) }
        let initial: Order
        switch scan.initialOrder {
        case .columns: initial = .columns
        case .rows: initial = .rows
        case .numbers: initial = .numbers
        }
        func entryList(_ indices: [UInt32]) -> [Entry] {
            indices.filter { !scan.words[Int($0)].stray }.map {
                let source = scan.words[Int($0)].reviewSource()
                return Entry(id: Int($0), word: source.read, source: source, checked: false, number: source.number)
            }
        }
        var entries: [Order: [Entry]] = [.columns: entryList(scan.columns), .rows: entryList(scan.rows)]
        if orders[.numbers] != nil { entries[.numbers] = entryList(scan.numbered) }
        return BackupReading(sequences: orders, initial: initial, requiresOrderReview: scan.orderRequiresReview,
                             entries: entries, frame: PhotoFrame(width: Int(scan.width), height: Int(scan.height)))
    }
}

/** Memory-only authority: exact matches or explicit acknowledgements of blind misreads.
 * Acknowledgement never changes the generated seed or the scanner's selections. */
@Observable @MainActor
final class NewSeedBackup {
    private let attempts = Attempts<BackupReading>()
    private var expected: [String] = []
    private var reading: BackupReading?
    private var orderReviewed = false
    private(set) var acknowledged: Set<Int> = []
    private(set) var stage: NewSeedStage = .idle
    private(set) var order: Order?
    private(set) var message: String?

    var words: [String] { expected }
    var attempt: Attempt<BackupReading>? { attempts.current }
    var availableOrders: Set<Order> { reading.map { Set($0.sequences.keys) } ?? [] }
    var readWords: [String] { order.flatMap { reading?.sequences[$0] } ?? [] }
    var entries: [Entry] {
        if let order, let entries = reading?.entries[order] { return entries }
        return readWords.enumerated().map { Entry(id: $0.offset, word: $0.element, source: nil, checked: false) }
    }
    var frame: PhotoFrame? { reading?.frame }

    func start(words: [String]) {
        precondition(words.count == 12)
        cancel()
        expected = words
        stage = .writing
    }

    func retake() {
        if stage == .idle { return }
        attempts.cancel()
        reading = nil
        order = nil
        orderReviewed = false
        acknowledged = []
        message = nil
        stage = .camera
    }

    func showWords() {
        if stage == .idle { return }
        retake()
        stage = .writing
    }

    func begin() -> Int {
        if stage != .camera || attempt != nil { return -1 }
        return attempts.begin()
    }

    @discardableResult
    func deliver(token: Int, photo: PhotoInput?) -> Bool {
        if stage != .camera || attempt?.token != token { return false }
        // Reject file/gallery data even if a caller manages to reach this method.
        let fresh = photo?.camera != nil ? photo : nil
        let accepted = attempts.deliverPhoto(token: token, photo: fresh)
        stage = accepted ? .reading : .review
        if !accepted { message = "Take a fresh camera photo of your written backup." }
        return accepted
    }

    @discardableResult
    func prepared(token: Int, photo: ResolvedPhoto) -> Bool { attempts.prepared(token: token, photo: photo) }

    @discardableResult
    func finish(token: Int, result: BackupReading) -> Bool {
        if !attempts.finish(token: token, result: result) { return false }
        reading = result
        acknowledged = []
        orderReviewed = !result.requiresOrderReview
        order = result.initial
        stage = .review
        assess()
        return true
    }

    func chooseOrder(value: Order) {
        if ![NewSeedStage.review, .verified].contains(stage) || !availableOrders.contains(value) { return }
        if order != value { acknowledged = [] }
        order = value
        orderReviewed = true
        assess()
    }

    func acknowledge(position: Int) {
        if stage != .review || !orderReviewed || readWords.count != 12 ||
            !expected.indices.contains(position) || readWords[position] == expected[position] { return }
        acknowledged.insert(position)
        assess()
    }

    private func assess() {
        guard reading != nil else { return }
        stage = .review
        if !orderReviewed {
            message = "Choose how you numbered or arranged the words on paper."
            return
        }
        let read = readWords
        if read.count != 12 {
            message = "Read \(read.count) words; all 12 are required. Retake the whole written list."
        } else {
            let mismatches = read.indices.filter { read[$0] != expected[$0] }
            if mismatches.allSatisfy({ acknowledged.contains($0) }) {
                message = mismatches.isEmpty ? "All 12 words match your generated phrase."
                    : "\(mismatches.count) misread words acknowledged. The generated phrase is unchanged."
                stage = .verified
            } else {
                message = "Words differ at positions \(mismatches.map { String($0 + 1) }.joined(separator: ", ")). " +
                    "Tap each wrong word to compare it with the generated word and check your paper."
            }
        }
    }

    func fail(token: Int) {
        if attempts.fail(token: token, message: "The photo could not be read. Please retake it.") {
            message = "The photo could not be read. Please retake it."
            stage = .review
        }
    }

    func consumeVerified() -> [String]? {
        if stage != .verified { return nil }
        let verified = expected
        cancel()
        return verified
    }

    func cancel() {
        attempts.cancel()
        expected = []
        reading = nil
        order = nil
        orderReviewed = false
        acknowledged = []
        message = nil
        stage = .idle
    }
}
