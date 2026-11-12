import XCTest
@testable import BitcoinVision

final class PhotoInputTests: XCTestCase {
    private func camera(_ rotation: Int) -> CameraPhotoMetadata {
        CameraPhotoMetadata(rotationDegrees: rotation, width: 6, height: 4, format: 256,
                            displayRotationAtShutter: 0, sensorToDisplayDegreesAtShutter: 90)
    }

    private func resolved(_ input: PhotoInput, _ orientation: Int, _ width: Int, _ height: Int,
                          _ photoUp: PhotoUpSource? = nil) -> ResolvedPhoto {
        if let photoUp {
            return ResolvedPhoto(source: input, orientation: orientation, rawWidth: width, rawHeight: height, photoUp: photoUp)
        }
        return ResolvedPhoto(source: input, orientation: orientation, rawWidth: width, rawHeight: height)
    }

    func test_camera_zero_is_present_and_file_has_no_camera_rotation() {
        let bytes = Data([1, 2, 3])
        for rotation in [0, 90, 180, 270] {
            let input = PhotoInput.fromCamera(bytes: bytes, metadata: camera(rotation))
            XCTAssertEqual(rotation, input.camera!.rotationDegrees)
            XCTAssertEqual(bytes, input.copyBytes())
        }
        XCTAssertNil(PhotoInput.fromFile(bytes: bytes).camera)
    }

    func test_caller_and_reader_mutation_cannot_change_the_retained_original() {
        var original = Data([1, 2, 3])
        let input = PhotoInput.fromCamera(bytes: original, metadata: camera(90))
        original[0] = 8
        var copy = input.copyBytes()
        copy[1] = 9
        let stream = input.openStream()
        stream.open()
        defer { stream.close() }
        XCTAssertEqual(Data([1, 2, 3]), readAtMost(input: stream))
    }

    func test_attempts_keep_their_own_framing_snapshot_without_applying_it() {
        let attempts = Attempts<String>()
        var metadata = camera(0)
        metadata.cropRect = CaptureBounds(left: 1, top: 0, right: 5, bottom: 4)
        metadata.previewAtShutter = CapturePreviewMetadata(
            bounds: CaptureBounds(left: 0, top: 0, right: 720, bottom: 1612), scaleType: "FILL_CENTER", layoutDirection: 0)
        let firstPhoto = PhotoInput.fromCamera(bytes: Data([1]), metadata: metadata)
        let first = attempts.begin()
        XCTAssertTrue(attempts.deliverPhoto(token: first, photo: firstPhoto))
        var secondMetadata = camera(90)
        secondMetadata.cropRect = CaptureBounds(left: 0, top: 1, right: 6, bottom: 3)
        secondMetadata.previewAtShutter = CapturePreviewMetadata(
            bounds: CaptureBounds(left: 0, top: 0, right: 480, bottom: 800), scaleType: "FIT_CENTER", layoutDirection: 0)
        let secondPhoto = PhotoInput.fromCamera(bytes: Data([2]), metadata: secondMetadata)
        let second = attempts.begin()
        XCTAssertFalse(attempts.deliverPhoto(token: first, photo: firstPhoto))
        XCTAssertTrue(attempts.deliverPhoto(token: second, photo: secondPhoto))
        XCTAssertTrue(secondPhoto === attempts.photo)
        XCTAssertEqual(CaptureBounds(left: 0, top: 1, right: 6, bottom: 3), attempts.photo!.camera!.cropRect)
        XCTAssertEqual(CaptureBounds(left: 1, top: 0, right: 5, bottom: 4), firstPhoto.camera!.cropRect)
        let resolvedPhoto = resolved(secondPhoto, 6, 6, 4)
        XCTAssertEqual(4, resolvedPhoto.width)
        XCTAssertEqual(6, resolvedPhoto.height)
        attempts.cancel()
        XCTAssertNil(attempts.photo)
    }

    func test_capture_metadata_follows_success_and_failure_and_is_dropped_on_cancel() {
        let attempts = Attempts<String>()
        let input = PhotoInput.fromCamera(bytes: Data([1]), metadata: camera(270))
        let first = attempts.begin()
        XCTAssertTrue(attempts.deliverPhoto(token: first, photo: input))
        XCTAssertTrue(attempts.prepared(token: first, photo: resolved(input, 8, 6, 4)))
        XCTAssertTrue(attempts.finish(token: first, result: "read"))
        XCTAssertTrue(input === attempts.photo)
        let second = attempts.begin()
        XCTAssertTrue(attempts.deliverPhoto(token: second, photo: input))
        XCTAssertTrue(attempts.fail(token: second, message: "blurred"))
        XCTAssertEqual(270, attempts.photo!.camera!.rotationDegrees)
        attempts.cancel()
        XCTAssertNil(attempts.photo)
        XCTAssertFalse(attempts.deliverPhoto(token: second, photo: input))
        let third = attempts.begin()
        XCTAssertFalse(attempts.deliverPhoto(token: second, photo: input))
        XCTAssertEqual(Attempt.capturing(token: third), attempts.current)
    }

    // Kotlin expects IllegalArgumentException from the constructor; Swift's
    // init traps on the same requirement, which `isValid` states without trapping.
    func test_invalid_camera_rotation_is_not_silently_treated_as_zero() {
        XCTAssertFalse(CameraPhotoMetadata.isValid(rotationDegrees: 45, width: 6, height: 4))
        for rotation in [0, 90, 180, 270] {
            XCTAssertTrue(CameraPhotoMetadata.isValid(rotationDegrees: rotation, width: 6, height: 4))
        }
        XCTAssertFalse(CameraPhotoMetadata.isValid(rotationDegrees: 0, width: 0, height: 4))
    }

    func test_transforms_are_selected_once_not_added_together() {
        let expected = [0: 1, 90: 6, 180: 3, 270: 8]
        for (rotation, orientation) in expected {
            for exif in 0...9 {
                XCTAssertEqual(orientation, orientationFromMetadata(camera: camera(rotation), exifOrientation: exif))
            }
        }
        for exif in 1...8 { XCTAssertEqual(exif, orientationFromMetadata(camera: nil, exifOrientation: exif)) }
        for exif in [nil, -1, 0, 9] as [Int?] {
            XCTAssertEqual(1, orientationFromMetadata(camera: nil, exifOrientation: exif))
        }
    }

    func test_identical_identity_transforms_keep_distinct_photo_up_provenance() {
        let cases: [(CameraPhotoMetadata?, Int?, PhotoUpSource)] = [
            (camera(0), nil, .camera),
            (nil, 1, .exif),
            (nil, nil, .unknown),
            (nil, 0, .unknown),
            (nil, 9, .unknown),
        ]
        for (camera, exif, source) in cases {
            XCTAssertEqual(1, orientationFromMetadata(camera: camera, exifOrientation: exif))
            XCTAssertEqual(source, photoUpFromMetadata(camera: camera, exifOrientation: exif))
        }
        for rotation in [0, 90, 180, 270] {
            for exif in [nil, -1, 0, 1, 6, 9] as [Int?] {
                XCTAssertEqual(.camera, photoUpFromMetadata(camera: camera(rotation), exifOrientation: exif))
            }
        }
        for exif in 1...8 { XCTAssertEqual(.exif, photoUpFromMetadata(camera: nil, exifOrientation: exif)) }
        XCTAssertEqual(.unknown, photoUpFromMetadata(camera: nil, exifOrientation: -1))
    }

    func test_resolved_photo_retains_provenance_without_inference_or_another_transform() {
        let input = PhotoInput.fromCamera(bytes: Data([1]), metadata: camera(90))
        // Legacy explicit-transform callers have not supplied a provenance hint.
        XCTAssertEqual(.unknown, resolved(input, 6, 6, 4).photoUp)
        let photo = resolved(input, 6, 6, 4, .camera)
        XCTAssertEqual(.camera, photo.photoUp)
        XCTAssertTrue(input === photo.source)
        XCTAssertEqual(6, photo.orientation)
        XCTAssertEqual(4, photo.width)
        XCTAssertEqual(6, photo.height)
    }

    /** iOS-only: the camera's EXIF tag read back as CameraX's rotation degrees resolves to the same transform. */
    func test_capture_exif_orientation_round_trips_through_camera_rotation() {
        for exif in [1, 6, 3, 8] {
            let degrees = cameraRotationDegrees(exifOrientation: exif)!
            XCTAssertEqual(exif, orientationFromMetadata(camera: camera(degrees), exifOrientation: nil))
        }
        for exif in [nil, 0, 2, 4, 5, 7, 9] as [Int?] { XCTAssertNil(cameraRotationDegrees(exifOrientation: exif)) }
    }
}
