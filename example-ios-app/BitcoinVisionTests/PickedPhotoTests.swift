import XCTest
@testable import BitcoinVision

/** A stream with no end, Kotlin's `object : InputStream()` that always fills the buffer. */
private final class EndlessStream: InputStream {
    override var hasBytesAvailable: Bool { true }
    override var streamStatus: Stream.Status { .open }
    override func open() {}
    override func close() {}
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        buffer.update(repeating: 0, count: len)
        return len
    }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length len: UnsafeMutablePointer<Int>) -> Bool { false }
}

final class PickedPhotoTests: XCTestCase {
    private func read(_ data: Data, limit: Int) -> Data? {
        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }
        return readAtMost(input: stream, limit: limit)
    }

    func test_a_document_within_the_limit_is_read_whole() {
        let bytes = Data((0..<200).map { UInt8($0) })
        XCTAssertEqual(bytes, read(bytes, limit: 256))
    }

    func test_a_document_of_exactly_the_limit_is_still_a_photo() {
        XCTAssertEqual(64, read(Data(count: 64), limit: 64)?.count)
    }

    func test_one_byte_past_the_limit_is_refused_rather_than_held() {
        XCTAssertNil(read(Data(count: 65), limit: 64))
    }

    func test_an_enormous_document_is_never_read_into_memory() {
        // A stream with no end: returning at all is the assertion.
        XCTAssertNil(readAtMost(input: EndlessStream(data: Data()), limit: 1024))
    }

    func test_an_empty_document_reads_as_empty_not_as_too_large() {
        XCTAssertEqual(0, read(Data(), limit: 64)?.count)
    }

    // The two `looksLikeEmulator` tests are not ported: the Android-only fixture
    // route they guard has no iOS counterpart.
}
