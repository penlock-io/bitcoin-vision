import Foundation

/** Immutable bounds copied from a view or a capture; no UIKit object is retained. */
struct CaptureBounds: Equatable, Hashable, Sendable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int
}

/** View geometry at the shutter, not when AVFoundation eventually delivers the image. */
struct CapturePreviewMetadata: Equatable, Hashable, Sendable {
    let bounds: CaptureBounds
    let scaleType: String
    let layoutDirection: Int
}

/** Capture-time facts, not a later reading of the phone's attitude. */
struct CameraPhotoMetadata: Equatable, Hashable, Sendable {
    var rotationDegrees: Int
    var width: Int
    var height: Int
    var format: Int
    var displayRotationAtShutter: Int?
    var sensorToDisplayDegreesAtShutter: Int?
    // Diagnostic only: verify per device that the fitted preview delivers a full-raster crop.
    // The preview fits the capture; these fields do not transform the scanned pixels.
    var cropRect: CaptureBounds? = nil
    var previewAtShutter: CapturePreviewMetadata? = nil

    init(
        rotationDegrees: Int,
        width: Int,
        height: Int,
        format: Int,
        displayRotationAtShutter: Int?,
        sensorToDisplayDegreesAtShutter: Int?,
        cropRect: CaptureBounds? = nil,
        previewAtShutter: CapturePreviewMetadata? = nil
    ) {
        // Kotlin's `require`: an invalid rotation is never silently treated as zero.
        precondition(Self.isValid(rotationDegrees: rotationDegrees, width: width, height: height),
                     "Invalid camera photo metadata")
        self.rotationDegrees = rotationDegrees
        self.width = width
        self.height = height
        self.format = format
        self.displayRotationAtShutter = displayRotationAtShutter
        self.sensorToDisplayDegreesAtShutter = sensorToDisplayDegreesAtShutter
        self.cropRect = cropRect
        self.previewAtShutter = previewAtShutter
    }

    /** The init's requirements, checkable without trapping. */
    static func isValid(rotationDegrees: Int, width: Int, height: Int) -> Bool {
        [0, 90, 180, 270].contains(rotationDegrees) && width > 0 && height > 0
    }
}

/**
 * An immutable encoded photo and its provenance. The camera's correction
 * cannot be recovered from the bytes alone. No transform is applied here.
 * Neither callers nor readers can mutate the retained diagnostic original
 * (`Data` is a value: every copy is the caller's own).
 */
final class PhotoInput: Sendable {
    private let encoded: Data
    let camera: CameraPhotoMetadata?

    private init(encoded: Data, camera: CameraPhotoMetadata?) {
        self.encoded = encoded
        self.camera = camera
    }

    var isEmpty: Bool { encoded.isEmpty }

    func copyBytes() -> Data { encoded }
    func openStream() -> InputStream { InputStream(data: encoded) }
    func writeTo(_ output: URL) throws { try encoded.write(to: output, options: .withoutOverwriting) }

    static func fromFile(bytes: Data) -> PhotoInput { PhotoInput(encoded: Data(bytes), camera: nil) }
    static func fromCamera(bytes: Data, metadata: CameraPhotoMetadata) -> PhotoInput {
        PhotoInput(encoded: Data(bytes), camera: metadata)
    }
    /** Only for the capture callback's fresh private copy: the caller relinquishes ownership. */
    static func ownCameraBytes(bytes: Data, metadata: CameraPhotoMetadata) -> PhotoInput {
        PhotoInput(encoded: bytes, camera: metadata)
    }
}

/** Kotlin compares these by identity (they are not data classes); so does Swift. */
extension PhotoInput: Hashable {
    static func == (lhs: PhotoInput, rhs: PhotoInput) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/** A resolved input is reused as-is; consumers never read EXIF or compose another turn. */
final class ResolvedPhoto: Sendable {
    let source: PhotoInput
    let orientation: Int
    let rawWidth: Int
    let rawHeight: Int
    // Never infer this from orientation == 1, or the presence of an orientation argument.
    let photoUp: PhotoUpSource

    init(source: PhotoInput, orientation: Int, rawWidth: Int, rawHeight: Int, photoUp: PhotoUpSource = .unknown) {
        precondition((1...8).contains(orientation) && rawWidth > 0 && rawHeight > 0, "Invalid resolved photo")
        self.source = source
        self.orientation = orientation
        self.rawWidth = rawWidth
        self.rawHeight = rawHeight
        self.photoUp = photoUp
    }

    var width: Int { orientation >= 5 ? rawHeight : rawWidth }
    var height: Int { orientation >= 5 ? rawWidth : rawHeight }
    var isEmpty: Bool { source.isEmpty }
}

extension ResolvedPhoto: Hashable {
    static func == (lhs: ResolvedPhoto, rhs: ResolvedPhoto) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/** Kotlin's `fun interface PhotoPreparer`: called as `try preparer.prepare(photo)`. */
struct PhotoPreparer: Sendable {
    let prepare: @Sendable (PhotoInput) throws -> ResolvedPhoto

    init(_ prepare: @escaping @Sendable (PhotoInput) throws -> ResolvedPhoto) {
        self.prepare = prepare
    }
}

struct PhotoPreparationException: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// `PhotoUpSource` is the generated UniFFI enum itself: provenance of canonical
// photo-up, not proof the paper was photographed upright.

/** Preserve provenance before missing EXIF collapses to the identity transform. */
func photoUpFromMetadata(camera: CameraPhotoMetadata?, exifOrientation: Int?) -> PhotoUpSource {
    if camera != nil { return .camera }
    if let exifOrientation, (1...8).contains(exifOrientation) { return .exif }
    return .unknown
}

/** EXIF-numbered transform; camera zero is authoritative, not a missing value. */
func orientationFromMetadata(camera: CameraPhotoMetadata?, exifOrientation: Int?) -> Int {
    if let camera {
        switch camera.rotationDegrees {
        case 0: return 1
        case 90: return 6
        case 180: return 3
        case 270: return 8
        default: preconditionFailure("Invalid camera rotation")
        }
    }
    if let exifOrientation, (1...8).contains(exifOrientation) { return exifOrientation }
    return 1
}

/**
 * The camera rotation an AVFoundation photo's EXIF orientation stands for:
 * the inverse of `orientationFromMetadata` for an unmirrored back camera.
 * AVFoundation records the connection's rotation as that tag, where CameraX
 * reports rotation degrees; nil for a mirrored or missing tag.
 */
func cameraRotationDegrees(exifOrientation: Int?) -> Int? {
    switch exifOrientation {
    case 1: return 0
    case 6: return 90
    case 3: return 180
    case 8: return 270
    default: return nil
    }
}
