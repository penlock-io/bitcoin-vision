import Foundation
import Observation

/** One photograph's journey from the shutter to its result. */
enum Attempt<R> {
    /** The shutter was pressed; the camera has not delivered the photo yet. */
    case capturing(token: Int)

    /** Raw bytes are in hand, but their orientation is not yet resolved. */
    case preparing(token: Int, photo: PhotoInput)

    /** Only resolved photos can be displayed or handed to a reader. */
    case processing(token: Int, photo: ResolvedPhoto)

    case done(token: Int, photo: ResolvedPhoto, result: R)

    /** The read failed, or the camera delivered nothing, in which case there is no photo. */
    case failed(token: Int, photo: ResolvedPhoto?, message: String, original: PhotoInput?)

    var token: Int {
        switch self {
        case let .capturing(token), let .preparing(token, _), let .processing(token, _),
             let .done(token, _, _), let .failed(token, _, _, _):
            return token
        }
    }
}

extension Attempt: Equatable where R: Equatable {}

/**
 * The attempts a scanner makes, one current at a time, owned by a
 * view model so an attempt outlives the camera on screen. Every step
 * names the attempt it belongs to, and only the current attempt may
 * move: what a cancelled or replaced attempt delivers later is dropped.
 */
@Observable
final class Attempts<R> {
    private(set) var current: Attempt<R>?
    @ObservationIgnored private var issued = 0

    init() {}

    /** Starts a new attempt at the shutter, replacing any other, and names it. */
    @discardableResult
    func begin() -> Int {
        issued += 1
        current = .capturing(token: issued)
        return issued
    }

    /**
     * The camera's photo for the attempt [token]. True when the read
     * may start; false when the attempt is no longer current, or the
     * camera delivered nothing, which fails it.
     */
    @discardableResult
    func deliver(token: Int, photo: Data?) -> Bool {
        if current?.token != token { return false }
        return deliverPhoto(token: token, photo: photo.map { PhotoInput.fromFile(bytes: $0) })
    }

    @discardableResult
    func deliverPhoto(token: Int, photo: PhotoInput?) -> Bool {
        guard case .capturing(token) = current else { return false }
        guard let photo, !photo.isEmpty else { return missing(token: token, message: "The camera gave no photo. Try again.") }
        current = .preparing(token: token, photo: photo)
        return true
    }

    /**
     * No photo ever arrived for [token], and why. Always false: there
     * is nothing to read. A photo can fail to arrive for reasons the
     * camera has no words for — a file the phone would not open — so
     * the reason is the caller's to give.
     */
    @discardableResult
    func missing(token: Int, message: String) -> Bool {
        guard case .capturing(token) = current else { return false }
        current = .failed(token: token, photo: nil, message: message, original: nil)
        return false
    }

    @discardableResult
    func prepared(token: Int, photo: ResolvedPhoto) -> Bool {
        guard case let .preparing(preparing, input) = current else { return false }
        if preparing != token || input !== photo.source { return false }
        current = .processing(token: token, photo: photo)
        return true
    }

    /** The result of the attempt [token]; false, and nothing changes, when it is no longer current. */
    @discardableResult
    func finish(token: Int, result: R) -> Bool {
        guard case let .processing(processing, photo) = current, processing == token else { return false }
        current = .done(token: token, photo: photo, result: result)
        return true
    }

    @discardableResult
    func fail(token: Int, message: String) -> Bool {
        guard let attempt = current, attempt.token == token else { return false }
        switch attempt {
        case let .preparing(_, photo):
            current = .failed(token: token, photo: nil, message: message, original: photo)
        case let .processing(_, photo):
            current = .failed(token: token, photo: photo, message: message, original: photo.source)
        default:
            return false
        }
        return true
    }

    /** Drops the current attempt; anything it still delivers is dropped too. */
    func cancel() {
        issued += 1
        current = nil
    }

    /** The photo of the current attempt, once the camera delivered it. */
    var photo: PhotoInput? {
        switch current {
        case let .preparing(_, photo): return photo
        case let .processing(_, photo): return photo.source
        case let .done(_, photo, _): return photo.source
        case let .failed(_, _, _, original): return original
        default: return nil
        }
    }

    var resolvedPhoto: ResolvedPhoto? {
        switch current {
        case let .processing(_, photo): return photo
        case let .done(_, photo, _): return photo
        case let .failed(_, photo, _, _): return photo
        default: return nil
        }
    }
}
