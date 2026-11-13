import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BitcoinVision

/** iOS-only: the ImageIO stand-ins for BitmapFactory and ExifInterface resolve as the Android app does. */
final class PhotoOrientationTests: XCTestCase {
    /** A 30x20 JPEG, optionally tagged with an EXIF orientation. */
    private func jpeg(orientation: Int?) throws -> Data {
        let context = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    func test_a_file_photo_takes_its_exif_turn_and_a_camera_photo_its_capture_turn() throws {
        let tagged = try jpeg(orientation: 6)
        let file = try resolvePhoto(photo: PhotoInput.fromFile(bytes: tagged))
        XCTAssertEqual(6, file.orientation)
        XCTAssertEqual(.exif, file.photoUp)
        XCTAssertEqual(30, file.rawWidth)
        XCTAssertEqual(20, file.rawHeight)
        XCTAssertEqual(20, file.width)
        XCTAssertEqual(30, file.height)

        let untagged = try resolvePhoto(photo: PhotoInput.fromFile(bytes: try jpeg(orientation: nil)))
        XCTAssertEqual(1, untagged.orientation)
        XCTAssertEqual(.unknown, untagged.photoUp)

        let metadata = CameraPhotoMetadata(rotationDegrees: 180, width: 30, height: 20, format: 256,
                                           displayRotationAtShutter: 0, sensorToDisplayDegreesAtShutter: 90)
        let camera = try resolvePhoto(photo: PhotoInput.fromCamera(bytes: tagged, metadata: metadata))
        XCTAssertEqual(3, camera.orientation)
        XCTAssertEqual(.camera, camera.photoUp)
    }

    func test_bytes_that_are_not_a_photo_are_refused_in_words() {
        XCTAssertThrowsError(try resolvePhoto(photo: PhotoInput.fromFile(bytes: Data([1, 2, 3])))) { error in
            XCTAssertEqual("The photo could not be opened. Try another.", (error as? PhotoPreparationException)?.message)
        }
    }

    func test_the_preview_is_turned_once_into_the_canonical_frame() throws {
        let photo = try resolvePhoto(photo: PhotoInput.fromFile(bytes: try jpeg(orientation: 6)))
        let preview = try XCTUnwrap(decodeSampled(photo: photo, longSide: 1280))
        XCTAssertEqual(photo.width, preview.width)
        XCTAssertEqual(photo.height, preview.height)
        let small = try XCTUnwrap(decodeSampled(photo: photo, longSide: 15))
        XCTAssertEqual(15, max(small.width, small.height))
        XCTAssertTrue(small.height > small.width)
    }
}
