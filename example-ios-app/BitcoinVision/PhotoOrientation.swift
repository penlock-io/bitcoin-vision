import CoreImage
import ImageIO
import SwiftUI

/**
 * Kotlin's coroutine `Mutex` for blocking work: one holder at a time, the
 * rest wait in order, and the body runs on the actor's executor, off Main.
 */
actor BlockingWorkLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { try body() }
}

/** Decoding a full-resolution photo is memory-heavy: one preparation at a time, app-wide. */
let photoPreparationLock = BlockingWorkLock()

/**
 * Kotlin's `withContext(Dispatchers.Default) { photoPreparationLock.withLock { preparer.prepare(photo) } }`:
 * the photo is resolved off Main, one at a time, before any pixels are displayed or scanned.
 */
func preparePhoto(_ photo: PhotoInput, with preparer: PhotoPreparer) async throws -> ResolvedPhoto {
    try await photoPreparationLock.withLock { try preparer.prepare(photo) }
}

/** Called on the attempt worker, once, before any pixels are displayed or scanned. */
func resolvePhoto(photo: PhotoInput) throws -> ResolvedPhoto {
    guard let image = CGImageSourceCreateWithData(photo.copyBytes() as CFData, nil),
          CGImageSourceGetCount(image) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          width > 0, height > 0
    else {
        throw PhotoPreparationException("The photo could not be opened. Try another.")
    }
    // A camera photo's turn is the capture's; only a file's EXIF tag is read.
    let exif = photo.camera == nil ? (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue : nil
    return ResolvedPhoto(
        source: photo, orientation: orientationFromMetadata(camera: photo.camera, exifOrientation: exif),
        rawWidth: width, rawHeight: height,
        photoUp: photoUpFromMetadata(camera: photo.camera, exifOrientation: exif)
    )
}

// No colour matching: the preview keeps the decoded pixels as they are.
private let orientationContext = CIContext(options: [.workingColorSpace: NSNull()])

/** Same eight-entry transform table as mobile/photo.rs, with no interpolation. */
func orientBitmap(bitmap: CGImage, orientation: Int) -> CGImage? {
    precondition((1...8).contains(orientation))
    if orientation == 1 { return bitmap }
    guard let exif = CGImagePropertyOrientation(rawValue: UInt32(orientation)) else { return nil }
    let oriented = CIImage(cgImage: bitmap).oriented(exif)
    return orientationContext.createCGImage(oriented, from: oriented.extent)
}

/** No encoded-byte copy beyond the decoder's and no full-resolution bitmap, including for quarter turns. */
func decodeSampled(photo: ResolvedPhoto, longSide: Int) -> CGImage? {
    precondition(longSide > 0)
    guard let source = CGImageSourceCreateWithData(photo.source.copyBytes() as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: min(longSide, max(photo.rawWidth, photo.rawHeight)),
        // The resolved orientation is applied below, never the file's own tag again.
        kCGImageSourceCreateThumbnailWithTransform: false,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return orientBitmap(bitmap: raw, orientation: photo.orientation)
}

/** Decodes the preview of [photo] off Main; nil when it cannot be decoded. */
func loadPhotoBitmap(_ photo: ResolvedPhoto, longSide: Int = 1280) async -> CGImage? {
    await Task.detached(priority: .userInitiated) { decodeSampled(photo: photo, longSide: longSide) }.value
}

/**
 * Kotlin's `rememberPhotoBitmap`: [content] gets the decoded preview of
 * [photo], or nil until a worker has decoded it. The state is keyed to the
 * photo itself: no frame shows the previous photo while a replacement is
 * still decoding, and a decode still under way when the photo goes is dropped.
 */
struct WithPhotoBitmap<Content: View>: View {
    let photo: ResolvedPhoto?
    @ViewBuilder let content: (CGImage?) -> Content

    init(_ photo: ResolvedPhoto?, @ViewBuilder content: @escaping (CGImage?) -> Content) {
        self.photo = photo
        self.content = content
    }

    var body: some View {
        Decoded(photo: photo, content: content).id(photo.map(ObjectIdentifier.init))
    }

    private struct Decoded: View {
        let photo: ResolvedPhoto?
        let content: (CGImage?) -> Content
        @State private var bitmap: CGImage?

        var body: some View {
            content(bitmap).task {
                guard let photo else { return }
                let decoded = await loadPhotoBitmap(photo)
                if !Task.isCancelled { bitmap = decoded }
            }
        }
    }
}
