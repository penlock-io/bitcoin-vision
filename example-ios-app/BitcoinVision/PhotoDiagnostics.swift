import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

#if DEBUG
private let debugBuild = true
#else
private let debugBuild = false
#endif

/** A diagnostic export refused or failed before any file was kept. */
enum PhotoDiagnosticError: Error {
    case releaseBuild
    case unreadable
}

/** Metadata only: never log a photo, its hash, OCR output or other EXIF fields. */
func photoDiagnosticMetadata(photo: PhotoInput) -> [String: Any] {
    let source = CGImageSourceCreateWithData(photo.copyBytes() as CFData, nil)
    var width = 0
    var height = 0
    var mimeType: Any = NSNull()
    var exifStatus = "read"
    var orientation: Int?
    if let source {
        if let type = CGImageSourceGetType(source) as String? {
            mimeType = UTType(type)?.preferredMIMEType ?? NSNull()
        }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        } else {
            exifStatus = "unreadable"
        }
    } else {
        exifStatus = "unreadable"
    }
    var json: [String: Any] = [
        "schema": 2,
        "source": photo.camera == nil ? "file" : "camera",
        "pixelTransformApplied": false,
        "encodedWidth": width,
        "encodedHeight": height,
        "mimeType": mimeType,
        "exifOrientation": orientation.map { $0 as Any } ?? NSNull(),
        "exifStatus": exifStatus,
        "orientationToCaptureTarget": orientationFromMetadata(camera: photo.camera, exifOrientation: orientation),
    ]
    if let camera = photo.camera {
        json["rotationDegrees"] = camera.rotationDegrees
        json["proxyWidth"] = camera.width
        json["proxyHeight"] = camera.height
        json["imageFormat"] = camera.format
        json["displayRotationAtShutter"] = camera.displayRotationAtShutter.map { $0 as Any } ?? NSNull()
        json["sensorToDisplayDegreesAtShutter"] = camera.sensorToDisplayDegreesAtShutter.map { $0 as Any } ?? NSNull()
        json["proxyCropRect"] = camera.cropRect.map { $0.json() as Any } ?? NSNull()
        json["previewAtShutter"] = camera.previewAtShutter.map { preview -> Any in
            [
                "boundsInParent": preview.bounds.json(),
                "scaleType": preview.scaleType,
                "layoutDirection": preview.layoutDirection,
            ] as [String: Any]
        } ?? NSNull()
        json["captureCropApplied"] = false
    }
    return json
}

private extension CaptureBounds {
    func json() -> [String: Any] { ["left": left, "top": top, "right": right, "bottom": bottom] }
}

private let captureLog = Logger(subsystem: "com.bitcoinvision.example", category: "VisionCapture")

func logPhotoInput(photo: PhotoInput) {
    if !debugBuild { return }
    // Diagnostics must not prevent the callback reaching its attempt.
    let metadata = photoDiagnosticMetadata(photo: photo)
    if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        captureLog.info("\(text, privacy: .public)")
    } else {
        captureLog.info("Capture metadata unavailable")
    }
}

/** Native result tied to the exact resolved capture, before any review edits. */
struct SavedScanDiagnosis {
    let photo: ResolvedPhoto
    let result: DiagnosedScan
}

/** Where a debug build keeps what the diagnosis buttons save: Documents/captures, pulled with Xcode. */
private func capturesDirectory() -> URL? {
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    let directory = documents.appendingPathComponent("captures", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        return nil
    }
    return directory
}

/** Java's `File.createTempFile`: a new, empty, uniquely named file; never an existing one. */
func createDiagnosticTempFile(prefix: String, suffix: String, directory: URL) throws -> URL {
    for _ in 0..<100 {
        let url = directory.appendingPathComponent("\(prefix)\(UInt64.random(in: 0...UInt64.max))\(suffix)")
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            return url
        } catch CocoaError.fileWriteFileExists {
            continue
        }
    }
    throw CocoaError(.fileWriteFileExists)
}

/** Only the explicit debug button calls this; capture itself never writes files. */
func saveRawPhotoForDiagnosis(photo: PhotoInput?, diagnosis: SavedScanDiagnosis? = nil) async -> String? {
    guard debugBuild, let photo else { return nil }
    return await Task.detached(priority: .utility) { () -> String? in
        guard let directory = capturesDirectory() else { return nil }
        do {
            let saved = try writeRawPhotoDiagnostic(photo: photo, directory: directory)
            let name = saved.lastPathComponent
            let message = "Saved raw photo as captures/\(name) and \(name).json"
            if let diagnosis, diagnosis.photo.source === photo {
                do {
                    let bundle = try writeScanDiagnostic(raw: saved, result: diagnosis.result) {
                        try canonicalPhoto(photo: photo.copyBytes(), orientation: UInt8(diagnosis.photo.orientation))
                    }
                    return "\(message); decisions and crops in captures/\(bundle.lastPathComponent)"
                } catch {
                    return "\(message); decision export failed (no complete bundle saved)"
                }
            }
            return "\(message). Processing decisions not included."
        } catch {
            return nil
        }
    }.value
}

private let canonicalExportLock = BlockingWorkLock()

/** Expensive full-resolution encoding is confined to this explicit debug action. */
func saveCanonicalPhotoForDiagnosis(photo: ResolvedPhoto?) async -> String? {
    guard debugBuild, let photo else { return nil }
    return await canonicalExportLock.withLock { () -> String? in
        var output: URL?
        do {
            guard let directory = capturesDirectory() else { return nil }
            let png = try canonicalPhoto(photo: photo.source.copyBytes(), orientation: UInt8(photo.orientation))
            let file = try createDiagnosticTempFile(prefix: "upright-scan-", suffix: ".png", directory: directory)
            output = file
            try png.write(to: file)
            return "Saved upright photo as captures/\(file.lastPathComponent)"
        } catch {
            if let output { try? FileManager.default.removeItem(at: output) }
            return nil
        }
    }
}

/** A uniquely named pair; the sidecar's digest binds capture-only metadata to these bytes. */
func writeRawPhotoDiagnostic(photo: PhotoInput, directory: URL) throws -> URL {
    guard debugBuild else { throw PhotoDiagnosticError.releaseBuild }
    var metadata = photoDiagnosticMetadata(photo: photo)
    let ext: String
    switch metadata["mimeType"] as? String {
    case "image/jpeg": ext = ".jpg"
    case "image/png": ext = ".png"
    default: ext = ".bin"
    }
    let image = try createDiagnosticTempFile(prefix: "raw-scan-", suffix: ext, directory: directory)
    let sidecar = directory.appendingPathComponent(image.lastPathComponent + ".json")
    do {
        let bytes = photo.copyBytes()
        try bytes.write(to: image)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        metadata["file"] = image.lastPathComponent
        metadata["sha256"] = digest
        let json = try JSONSerialization.data(withJSONObject: metadata,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (json + Data("\n".utf8)).write(to: sidecar)
        return image
    } catch {
        // Only these newly created files: never leave a misleading half-pair.
        try? FileManager.default.removeItem(at: sidecar)
        try? FileManager.default.removeItem(at: image)
        throw error
    }
}
