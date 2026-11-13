import Foundation

/** A saved wallet: public data only, never the phrase. */
struct WalletRecord: Equatable, Hashable {
    let id: String
    var name: String
    let fingerprint: String
    let descriptor: String
    /** ISO date. */
    let created: String
    /** The ISO date two written strips last read back as the key, if ever. */
    var penlockBackup: String?
}

/** The wallets on disk: one JSON file under the app's files, written whole. */
final class WalletStore {
    private let file: URL

    init(file: URL) {
        self.file = file
    }

    convenience init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(file: dir.appendingPathComponent("wallets.json"))
    }

    /**
     * The saved list. A file that is there but unreadable stops the app, as the
     * Android app's does: reading it as empty would let the next save erase it.
     */
    func load() -> [WalletRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let data = try Data(contentsOf: file)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                fatalError("\(file.lastPathComponent) is not a list of wallets")
            }
            return try array.map { o in
                func string(_ key: String) throws -> String {
                    guard let value = o[key] as? String else { throw StoreError.missing(key) }
                    return value
                }
                return WalletRecord(
                    id: try string("id"),
                    name: try string("name"),
                    fingerprint: try string("fingerprint"),
                    descriptor: try string("descriptor"),
                    created: try string("created"),
                    penlockBackup: o["penlockBackup"] as? String
                )
            }
        } catch {
            fatalError("could not read \(file.lastPathComponent): \(error)")
        }
    }

    func save(_ wallets: [WalletRecord]) {
        let array: [[String: Any]] = wallets.map { w in
            [
                "id": w.id,
                "name": w.name,
                "fingerprint": w.fingerprint,
                "descriptor": w.descriptor,
                "created": w.created,
                "penlockBackup": w.penlockBackup ?? NSNull(),
            ]
        }
        // Written beside and renamed over (an atomic write), so a crash
        // mid-write leaves the old list rather than half of the new one.
        do {
            let data = try JSONSerialization.data(withJSONObject: array)
            try data.write(to: file, options: .atomic)
        } catch {
            fatalError("could not replace \(file.lastPathComponent)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    private enum StoreError: Error {
        case missing(String)
    }
}
