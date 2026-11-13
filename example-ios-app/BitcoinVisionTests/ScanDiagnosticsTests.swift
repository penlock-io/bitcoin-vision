import CryptoKit
import XCTest
@testable import BitcoinVision

/** Synthetic DTOs only: no native library, detector, OCR, or device. */
final class ScanDiagnosticsTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func fixture() -> DiagnosedScan {
        let word = WordReading(
            corners: (0..<8).map(Float.init), ranked: [], accepted: false, confidence: 0, alternatives: [],
            read: "fox", raw: "x",
            originalOcr: OcrObservation(corners: Array(repeating: 2, count: 8), cropPng: Data([8, 9]), raw: "7."),
            matching: nil, labels: [], labelConflict: false, stray: false,
            number: nil, apart: false, cropPng: Data([1, 2, 3]),
            joinedFrom: [], expandedFrom: []
        )
        let scan = PhraseScan(
            listNumbered: false, layout: .page, width: 100, height: 200, words: [word], columns: [0], rows: [0],
            columnsPass: false, rowsPass: false, numbering: .none, numbered: [0], numberedPass: false,
            initialOrder: .columns, orderRequiresReview: false, orderBasis: "same_retained_traversal", sources: []
        )
        let files = ["manifest.json", "final-boxes.jsonl", "word-links.jsonl", "readings.jsonl",
                     "sources.jsonl", "numbering.jsonl", "ordering.jsonl", "joins.jsonl"]
            .map { DiagnosticFile(name: $0, text: "{\"recorded\":\"\($0)\"}\n") }
        return DiagnosedScan(scan: scan, files: files)
    }

    private func raw() throws -> URL {
        let raw = temp.appendingPathComponent("raw-scan.bin")
        try Data([4, 5, 6]).write(to: raw)
        try Data("{\"source\":\"fixture\"}\n".utf8).write(to: URL(fileURLWithPath: raw.path + ".json"))
        return raw
    }

    private func listing() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
    }

    private struct FixtureFailure: Error {}

    func test_saves_existing_crop_and_trace_bytes_and_binds_every_file() throws {
        let raw = try raw()
        let result = fixture()
        var encodes = 0
        let saved = try writeScanDiagnostic(raw: raw, result: result) { encodes += 1; return Data([11, 12]) }
        XCTAssertEqual(1, encodes)
        func bytes(_ path: String) throws -> Data { try Data(contentsOf: saved.appendingPathComponent(path)) }
        XCTAssertEqual(Data([11, 12]), try bytes("photo.png"))
        XCTAssertEqual(result.scan.words[0].cropPng, try bytes("stage/crops/photo.png~w0.png"))
        XCTAssertEqual(result.scan.words[0].originalOcr!.cropPng, try bytes("stage/original-crops/photo.png~w0.png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: raw.path + ".json")), try bytes("capture.json"))
        for file in result.files { XCTAssertEqual(Data(file.text.utf8), try bytes("stage/\(file.name)")) }
        let sums = String(decoding: try bytes("SHA256SUMS"), as: UTF8.self)
        var covered = Set<String>()
        for line in sums.split(separator: "\n") {
            let parts = line.components(separatedBy: "  ")
            XCTAssertEqual(2, parts.count)
            let actual = SHA256.hash(data: try bytes(parts[1])).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(parts[0], actual)
            covered.insert(parts[1])
        }
        XCTAssertEqual(Set(try diagnosticFiles(under: saved).filter { $0 != "SHA256SUMS" }), covered)
        XCTAssertEqual(Data([4, 5, 6]), try Data(contentsOf: raw))
        // Existing evidence is never overwritten, including when Save is retried.
        XCTAssertThrowsError(try writeScanDiagnostic(raw: raw, result: result) {
            XCTFail("must not encode")
            return Data()
        }) { error in
            guard case .illegalState = error as? ScanDiagnosticError else { return XCTFail("\(error)") }
        }
    }

    func test_failed_save_leaves_only_the_raw_pair_and_invalid_names_never_write() throws {
        let raw = try raw()
        let result = fixture()
        let pair: Set<String> = [raw.lastPathComponent, raw.lastPathComponent + ".json"]
        XCTAssertThrowsError(try writeScanDiagnostic(raw: raw, result: result) { throw FixtureFailure() }) { error in
            XCTAssertTrue(error is FixtureFailure)
        }
        XCTAssertEqual(pair, try listing())
        for bad in [[], result.files + [result.files[0]],
                    Array(result.files.dropLast()) + [DiagnosticFile(name: "../escape.json", text: "{}")]] {
            var copy = result
            copy.files = bad
            XCTAssertThrowsError(try writeScanDiagnostic(raw: raw, result: copy) {
                XCTFail("must not encode")
                return Data()
            }) { error in
                guard case .illegalArgument = error as? ScanDiagnosticError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(pair, try listing())
        // Failure after canonical encoding must clean its incomplete directory too.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: raw.path + ".json"))
        XCTAssertThrowsError(try writeScanDiagnostic(raw: raw, result: result) { Data([11]) })
        XCTAssertEqual([raw.lastPathComponent], try listing())
    }
}
