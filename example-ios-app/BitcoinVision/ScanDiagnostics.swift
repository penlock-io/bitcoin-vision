import CryptoKit
import Foundation

#if DEBUG
private let debugBuild = true
#else
private let debugBuild = false
#endif

private let diagnosticNames: Set<String> = ["manifest.json", "final-boxes.jsonl", "word-links.jsonl",
    "readings.jsonl", "sources.jsonl", "numbering.jsonl", "ordering.jsonl", "joins.jsonl"]

/** Kotlin's `check`/`require` failures: refused before anything is written. */
enum ScanDiagnosticError: Error, Equatable {
    /** IllegalStateException: a release build, or evidence already saved for this capture. */
    case illegalState(String)
    /** IllegalArgumentException: the native result does not carry exactly the recorded files. */
    case illegalArgument(String)
}

/**
 * Explicit-save writer: immutable native result, already encoded crops, and a
 * canonical-photo encoder supplied by the caller. Never calls a scanner.
 */
func writeScanDiagnostic(raw: URL, result: DiagnosedScan, canonical: () throws -> Data) throws -> URL {
    guard debugBuild else { throw ScanDiagnosticError.illegalState("Diagnostics are debug-only") }
    let names = result.files.map(\.name)
    guard Set(names) == diagnosticNames && result.files.count == diagnosticNames.count else {
        throw ScanDiagnosticError.illegalArgument("Unexpected diagnostic files")
    }
    let files = FileManager.default
    let directory = raw.deletingLastPathComponent()
    let destination = directory.appendingPathComponent(raw.lastPathComponent + ".scan", isDirectory: true)
    guard !files.fileExists(atPath: destination.path) else {
        throw ScanDiagnosticError.illegalState("Diagnostic destination already exists")
    }
    let staging = try createStagingDirectory(in: directory)
    do {
        let stage = staging.appendingPathComponent("stage", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        let crops = stage.appendingPathComponent("crops", isDirectory: true)
        try files.createDirectory(at: crops, withIntermediateDirectories: false)
        try canonical().write(to: staging.appendingPathComponent("photo.png"), options: .withoutOverwriting)
        try files.copyItem(at: URL(fileURLWithPath: raw.path + ".json"),
                           to: staging.appendingPathComponent("capture.json"))
        for file in result.files {
            try Data(file.text.utf8).write(to: stage.appendingPathComponent(file.name), options: .withoutOverwriting)
        }
        for (index, word) in result.scan.words.enumerated() {
            let name = "photo.png~w\(index).png"
            try word.cropPng.write(to: crops.appendingPathComponent(name), options: .withoutOverwriting)
            if let original = word.originalOcr {
                let originals = stage.appendingPathComponent("original-crops", isDirectory: true)
                try files.createDirectory(at: originals, withIntermediateDirectories: true)
                try original.cropPng.write(to: originals.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }
        // Bind every exported byte; capture.json also binds the raw image saved
        // beside this bundle. No hashes, pixels or recognized words enter logs.
        let sums = try diagnosticFiles(under: staging).map { path -> String in
            let bytes = try Data(contentsOf: staging.appendingPathComponent(path))
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "  " + path
        }.joined(separator: "\n") + "\n"
        try Data(sums.utf8).write(to: staging.appendingPathComponent("SHA256SUMS"), options: .withoutOverwriting)
        try files.moveItem(at: staging, to: destination) // no overwrite
        return destination
    } catch {
        try? files.removeItem(at: staging) // only this call's private, newly created staging directory
        throw error
    }
}

/** Every regular file under [root], as sorted relative paths with `/` separators. */
func diagnosticFiles(under root: URL) throws -> [String] {
    let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var paths: [String] = []
    for case let url as URL in walker {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        paths.append(components.dropFirst(base.count).joined(separator: "/"))
    }
    return paths.sorted()
}

/** Java's `Files.createTempDirectory(directory, ".scan-writing-")`. */
private func createStagingDirectory(in directory: URL) throws -> URL {
    for _ in 0..<100 {
        let url = directory.appendingPathComponent(".scan-writing-\(UInt64.random(in: 0...UInt64.max))",
                                                   isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch CocoaError.fileWriteFileExists {
            continue
        }
    }
    throw CocoaError(.fileWriteFileExists)
}
