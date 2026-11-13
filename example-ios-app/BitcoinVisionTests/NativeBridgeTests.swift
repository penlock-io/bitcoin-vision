import XCTest
@testable import BitcoinVision

/**
 * The Rust bridge as the app runs it on iOS: the static library linked in,
 * the models loaded from the app bundle, the bindings crossing both ways.
 * The other test classes pin Swift decisions with fakes; these are the
 * ones that would fail if the native half were missing or mislinked.
 */
final class NativeBridgeTests: XCTestCase {
    /** The repository's example page: a handwritten 12-word phrase. */
    private var examplePhoto: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("words/examples/photos/handwritten.png")
    }

    func testTheBundledModelsReadTheExamplePage() throws {
        let bytes = try Data(contentsOf: examplePhoto)
        let photo = try resolvePhoto(photo: .fromFile(bytes: bytes))
        let scan = try NativePhraseReader().scan(photo: photo, observer: ScanProgressHandoff(token: 1))
        XCTAssertEqual(scan.words.count, 12)
        XCTAssertTrue(checksumPasses(words: scan.words.map(\.read)), "the example page's phrase reads with a valid checksum")
    }

    func testANewPhraseMakesAWalletAndPenlockShares() throws {
        let words = try newPhrase()
        XCTAssertEqual(words.count, 12)
        XCTAssertTrue(checksumPasses(words: words))
        let wallet = try descriptor(words: words)
        XCTAssertEqual(wallet.fingerprint.count, 8)
        XCTAssertFalse(wallet.descriptor.isEmpty)
        XCTAssertFalse(try splitPhrase(words: words).isEmpty)
    }

    func testTheStripModelLoadsFromTheBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cell-reference", withExtension: "onnx", subdirectory: "models"))
        XCTAssertNoThrow(try Scanner(model: Data(contentsOf: url)))
    }
}
