import Foundation
import Observation

/** Where a loaded key came from. */
enum KeySource: Equatable, Hashable {
    case new
    case writtenPhrase
    case strips(first: UInt8, second: UInt8)
}

/** A wallet's key while it is in memory. */
final class LoadedKey {
    let words: [String]
    let source: KeySource

    init(words: [String], source: KeySource) {
        self.words = words
        self.source = source
    }
}

/** The next task suggested by a wallet's current state. */
enum WalletAction: Equatable, Hashable, CaseIterable {
    case review, backUp, sign, loadKey
}

/** What two photographed strips read back against the key: the first
 * row that differs, or none. */
struct StripCheck {
    let read: [String]
    let mismatch: Int?
}

/** A Penlock backup under way for one wallet. */
struct Backup {
    let walletId: String
    let shares: [ShareText]
    let check: StripCheck?
}

/** A line for one wallet's page: a refusal, or a note on what just happened. */
struct Notice {
    let walletId: String
    let text: String
    let refusal: Bool
}

/** A PSBT that came in, as far as it got. */
enum Signing {
    /** Reviewed against a saved wallet, waiting for the word. */
    case pending(walletId: String, review: Review)
    case refused(walletId: String?, reason: String)
    case signed(walletId: String, review: Review, bytes: Data)

    var walletId: String? {
        switch self {
        case let .pending(walletId, _): return walletId
        case let .refused(walletId, _): return walletId
        case let .signed(walletId, _, _): return walletId
        }
    }
}

/**
 * The wallets: descriptors saved on disk, keys held in memory for as
 * long as they are wanted. The saved descriptor is the oracle for
 * whether a phrase is a wallet's key, and what a PSBT is held to.
 */
@Observable @MainActor
final class WalletsViewModel {
    @ObservationIgnored private let store: WalletStore

    private(set) var wallets: [WalletRecord]
    private(set) var keys: [String: LoadedKey] = [:]

    /** The wallet whose phrase is on screen. */
    var revealed: String?
    private(set) var backup: Backup?
    private(set) var notice: Notice?
    private(set) var signing: Signing?

    init(store: WalletStore = WalletStore()) {
        self.store = store
        self.wallets = store.load()
    }

    func wallet(id: String) -> WalletRecord? { wallets.first { $0.id == id } }

    /** Names are public labels, not wallet identities. At most 40 Unicode code points. */
    @discardableResult
    func rename(id: String, name: String) -> Bool {
        guard let trimmed = normalizedWalletName(input: name) else { return false }
        guard let index = wallets.firstIndex(where: { $0.id == id }) else { return false }
        wallets[index].name = trimmed
        store.save(wallets)
        return true
    }

    func needsBackupWarning(id: String) -> Bool {
        key(id: id)?.source == .new && wallet(id: id)?.penlockBackup == nil
    }

    func nextAction(id: String) -> WalletAction {
        if case let .pending(walletId, _) = signing, walletId == id { return .review }
        if needsBackupWarning(id: id) { return .backUp }
        if key(id: id) != nil { return .sign }
        return .loadKey
    }

    func key(id: String) -> LoadedKey? { keys[id] }

    private func derive(_ words: [String]) -> WalletDescriptor? {
        try? descriptor(words: words)
    }

    /**
     * Takes `words` as a wallet: the saved one with this descriptor,
     * its key now loaded, or a new one saved with its key loaded. The
     * wallet's id, or nil when the words are not a phrase.
     */
    func take(words: [String], source: KeySource) -> String? {
        if source == .new { return nil }
        return saveKey(words, source)
    }

    private func saveKey(_ words: [String], _ source: KeySource) -> String? {
        guard let derived = derive(words) else { return nil }
        if let existing = wallets.first(where: { $0.descriptor == derived.descriptor }) {
            keys[existing.id] = LoadedKey(words: words, source: source)
            notice = Notice(walletId: existing.id, text: "Already here as \(existing.name). Its key is loaded.", refusal: false)
            return existing.id
        }
        let record = WalletRecord(
            id: UUID().uuidString.lowercased(),
            name: "Wallet \(nextNumber())",
            fingerprint: derived.fingerprint,
            descriptor: derived.descriptor,
            created: isoToday(),
            penlockBackup: nil
        )
        wallets.append(record)
        store.save(wallets)
        keys[record.id] = LoadedKey(words: words, source: source)
        // Generation reaches here only after its photographed backup is verified.
        notice = nil
        return record.id
    }

    /** The only generated-key completion path consumes one verified photo session. */
    func completeNew(creation: NewSeedViewModel) -> String? {
        guard let words = creation.consumeVerified() else { return nil }
        return saveKey(words, .new)
    }

    /** Loads `words` as `id`'s key. Another wallet's phrase is refused by fingerprint. */
    func loadInto(id: String, words: [String], source: KeySource) -> Bool {
        if source == .new { return false }
        guard let wallet = wallet(id: id) else { return false }
        guard let derived = derive(words) else { return false }
        if derived.descriptor != wallet.descriptor {
            notice = Notice(
                walletId: id,
                text: "That is not this wallet's key: its fingerprint is \(derived.fingerprint), " +
                    "this wallet's is \(wallet.fingerprint).",
                refusal: true
            )
            return false
        }
        keys[id] = LoadedKey(words: words, source: source)
        notice = nil
        return true
    }

    func unload(id: String) {
        keys.removeValue(forKey: id)
        if revealed == id { revealed = nil }
        if backup?.walletId == id { backup = nil }
        if notice?.walletId == id { notice = nil }
        if signing?.walletId == id { signing = nil }
    }

    func forget(id: String) {
        unload(id: id)
        wallets.removeAll { $0.id == id }
        store.save(wallets)
    }

    /** Splits `id`'s key. True when the shares are ready to show. */
    func makeShares(id: String) -> Bool {
        guard let key = keys[id] else { return false }
        do {
            backup = Backup(walletId: id, shares: try splitPhrase(words: key.words), check: nil)
            return true
        } catch {
            return false
        }
    }

    /** Compares what two strips recovered with the key being backed
     * up; a match is the backup checked, and recorded on the wallet. */
    func checkStrips(read: [String]) {
        guard let backup else { return }
        guard let key = keys[backup.walletId] else { return }
        let words = key.words
        let mismatch = (0..<max(words.count, read.count)).first { i in
            (i < words.count ? words[i] : nil) != (i < read.count ? read[i] : nil)
        }
        self.backup = Backup(walletId: backup.walletId, shares: backup.shares, check: StripCheck(read: read, mismatch: mismatch))
        if mismatch != nil { return }
        if let i = wallets.firstIndex(where: { $0.id == backup.walletId }) {
            wallets[i].penlockBackup = isoToday()
            store.save(wallets)
        }
    }

    func endBackup() {
        backup = nil
    }

    /**
     * Takes a PSBT that came in, binary or base64 text, reviewed
     * against every saved wallet. Whatever was pending is replaced.
     */
    func receive(_ bytes: Data) {
        do {
            let review = try reviewPsbt(descriptors: wallets.map(\.descriptor), psbt: asPsbtBytes(bytes: bytes))
            if let wallet = wallets.first(where: { $0.descriptor == review.descriptor() }) {
                signing = .pending(walletId: wallet.id, review: review)
            } else {
                signing = .refused(walletId: nil, reason: "No saved wallet has this transaction's descriptor.")
            }
        } catch {
            signing = .refused(walletId: nil, reason: refusalDetail(error) ?? "The transaction was refused.")
        }
    }

    /**
     * Signs `pending` with its wallet's loaded key, only while it is
     * still the request on the table: consent given to one transaction
     * does not carry to whatever replaced it. True when signed.
     *
     * `pending` must be a `.pending` request; the request on the table is
     * matched by the identity of its review, as the Android app matches the
     * request object itself.
     */
    func sign(pending: Signing) -> Bool {
        guard case let .pending(walletId, review) = pending,
              case let .pending(currentId, currentReview) = signing,
              currentReview === review, currentId == walletId
        else { return false }
        guard let key = keys[walletId] else { return false }
        do {
            let bytes = try signReview(review: review, words: key.words)
            // The Android debug build also writes the signed PSBT where the
            // emulator gate (adb) reads it; there is no such reader on iOS.
            signing = .signed(walletId: walletId, review: review, bytes: bytes)
        } catch {
            signing = .refused(walletId: walletId, reason: refusalDetail(error) ?? "The transaction could not be signed.")
        }
        if case .signed = signing { return true }
        return false
    }

    func dismissSigning() {
        signing = nil
    }

    /** Opening a wallet's page drops a request that was another wallet's. */
    func leaveSigningUnless(_ id: String) {
        if let owner = signing?.walletId, owner != id { signing = nil }
    }

    private func nextNumber() -> Int {
        let numbers = wallets.compactMap { w -> Int? in
            let name = w.name.hasPrefix("Wallet ") ? String(w.name.dropFirst("Wallet ".count)) : w.name
            return Int(name)
        }
        return (numbers.max() ?? 0) + 1
    }
}

/** The native error's own words, as the Android app reads them from the exception message. */
private func refusalDetail(_ error: Error) -> String? {
    guard let vision = error as? VisionError else { return nil }
    switch vision {
    case let .Photo(detail), let .Model(detail), let .Scan(detail), let .Qr(detail),
         let .Recover(detail), let .Phrase(detail), let .Psbt(detail):
        return detail
    }
}

/** Today's date as ISO `yyyy-MM-dd`, in the phone's time zone (as `LocalDate.now()`). */
private func isoToday() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

private let PSBT_MAGIC = Data([0x70, 0x73, 0x62, 0x74, 0xFF])

/** The PSBT's bytes, whether they came as the file or as its base64 text. */
func asPsbtBytes(bytes: Data) -> Data {
    if bytes.count >= PSBT_MAGIC.count && bytes.prefix(PSBT_MAGIC.count) == PSBT_MAGIC {
        return bytes
    }
    // Android's decoder skips characters outside the alphabet and accepts
    // missing padding; this reads the same text the same way.
    let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
        return decoded
    }
    let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    let kept = String(text.filter { alphabet.contains($0) })
    let remainder = kept.count % 4
    if remainder >= 2, let decoded = Data(base64Encoded: kept + String(repeating: "=", count: 4 - remainder)) {
        return decoded
    }
    return bytes
}
