import XCTest
@testable import BitcoinVision

final class AttemptsTests: XCTestCase {
    private let photo = Data([1, 2, 3])

    private func resolved(_ input: PhotoInput, _ orientation: Int, _ width: Int, _ height: Int) -> ResolvedPhoto {
        ResolvedPhoto(source: input, orientation: orientation, rawWidth: width, rawHeight: height)
    }

    private func failed(_ attempt: Attempt<String>?) -> (photo: ResolvedPhoto?, message: String)? {
        if case let .failed(_, photo, message, _) = attempt { return (photo, message) }
        return nil
    }

    func test_an_attempt_moves_from_the_shutter_through_the_photo_to_its_result() {
        let attempts = Attempts<String>()
        XCTAssertNil(attempts.current)
        let token = attempts.begin()
        XCTAssertEqual(Attempt.capturing(token: token), attempts.current)
        XCTAssertTrue(attempts.deliver(token: token, photo: photo))
        guard case .preparing = attempts.current else { return XCTFail("not preparing") }
        XCTAssertTrue(attempts.prepared(token: token, photo: resolved(attempts.photo!, 1, 3, 1)))
        guard case .processing = attempts.current else { return XCTFail("not processing") }
        XCTAssertTrue(attempts.finish(token: token, result: "words"))
        guard case let .done(_, _, result) = attempts.current else { return XCTFail("not done") }
        XCTAssertEqual("words", result)
        XCTAssertEqual(photo, attempts.photo!.copyBytes())
    }

    func test_a_photo_that_never_arrived_fails_in_the_words_of_whoever_went_looking() {
        let attempts = Attempts<String>()
        let token = attempts.begin()
        // The file route's reasons are not the camera's, and a person
        // who picked a file is not told to try taking it again.
        XCTAssertFalse(attempts.missing(token: token, message: "That file could not be opened. Choose another."))
        let failure = failed(attempts.current)
        XCTAssertEqual("That file could not be opened. Choose another.", failure?.message)
        XCTAssertNotNil(failure)
        XCTAssertNil(failure?.photo)
    }

    func test_a_stale_token_cannot_fail_the_attempt_that_replaced_it() {
        let attempts = Attempts<String>()
        let stale = attempts.begin()
        let current = attempts.begin()
        XCTAssertFalse(attempts.missing(token: stale, message: "gone"))
        XCTAssertEqual(Attempt.capturing(token: current), attempts.current)
    }

    func test_a_failed_read_keeps_the_photo_and_a_camera_that_gave_nothing_fails_without_one() {
        let attempts = Attempts<String>()
        let token = attempts.begin()
        attempts.deliver(token: token, photo: photo)
        XCTAssertTrue(attempts.prepared(token: token, photo: resolved(attempts.photo!, 1, 3, 1)))
        XCTAssertTrue(attempts.fail(token: token, message: "blurred"))
        let failure = failed(attempts.current)
        XCTAssertEqual("blurred", failure?.message)
        XCTAssertEqual(photo, failure?.photo?.source.copyBytes())
        let again = attempts.begin()
        XCTAssertFalse(attempts.deliver(token: again, photo: Data()))
        XCTAssertNotNil(failed(attempts.current))
        XCTAssertNil(failed(attempts.current)?.photo)
        XCTAssertFalse(attempts.finish(token: again, result: "words"))
    }

    func test_a_cancelled_attempt_delivers_nothing_and_neither_does_one_replaced() {
        let attempts = Attempts<String>()
        let first = attempts.begin()
        attempts.cancel()
        XCTAssertNil(attempts.current)
        // the camera's late photo for a cancelled attempt
        XCTAssertFalse(attempts.deliver(token: first, photo: photo))
        XCTAssertNil(attempts.current)
        // a read that ends after its attempt was cancelled
        let second = attempts.begin()
        attempts.deliver(token: second, photo: photo)
        attempts.cancel()
        XCTAssertFalse(attempts.finish(token: second, result: "words"))
        XCTAssertFalse(attempts.fail(token: second, message: "late"))
        XCTAssertNil(attempts.current)
        // a read that ends after another attempt replaced it
        let third = attempts.begin()
        attempts.deliver(token: third, photo: photo)
        let fourth = attempts.begin()
        XCTAssertFalse(attempts.finish(token: third, result: "stale"))
        XCTAssertEqual(Attempt.capturing(token: fourth), attempts.current)
        XCTAssertFalse(attempts.deliver(token: third, photo: photo))
        XCTAssertEqual(Attempt.capturing(token: fourth), attempts.current)
    }

    func test_preparation_cannot_publish_after_cancel_replacement_or_twice() {
        let attempts = Attempts<String>()
        let first = attempts.begin()
        attempts.deliver(token: first, photo: photo)
        let firstResolved = resolved(attempts.photo!, 6, 3, 1)
        XCTAssertFalse(attempts.finish(token: first, result: "too early"))
        attempts.cancel()
        XCTAssertFalse(attempts.prepared(token: first, photo: firstResolved))
        let second = attempts.begin()
        attempts.deliver(token: second, photo: photo)
        XCTAssertFalse(attempts.prepared(token: first, photo: firstResolved))
        XCTAssertFalse(attempts.prepared(token: second, photo: firstResolved)) // Another input, even with the right token.
        let next = resolved(attempts.photo!, 6, 3, 1)
        XCTAssertTrue(attempts.prepared(token: second, photo: next))
        XCTAssertFalse(attempts.prepared(token: second, photo: next))
        XCTAssertTrue(next === attempts.resolvedPhoto)
        XCTAssertTrue(attempts.finish(token: second, result: "read"))
        XCTAssertTrue(next === attempts.resolvedPhoto)
        XCTAssertFalse(attempts.deliver(token: second, photo: photo))
    }
}
