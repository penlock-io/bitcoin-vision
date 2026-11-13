import XCTest
@testable import BitcoinVision

final class PhotoFitTests: XCTestCase {
    func test_all_eight_canonical_marker_positions_are_fitted_without_another_transform() {
        // Native/preview already oriented the raw 3x2 marker. The overlay must
        // use these canonical coordinates as-is, including mirrored transforms.
        let points: [(Float, Float)] = [(0.5, 0.5), (2.5, 0.5), (2.5, 1.5), (0.5, 1.5),
                                        (0.5, 0.5), (1.5, 0.5), (1.5, 2.5), (0.5, 2.5)]
        let pixels: [(Float, Float)] = [(100, 200), (500, 200), (500, 400), (100, 400),
                                        (200, 100), (400, 100), (400, 500), (200, 500)]
        for orientation in 1...8 {
            let photo = ResolvedPhoto(source: PhotoInput.fromFile(bytes: Data([1])), orientation: orientation,
                                      rawWidth: 3, rawHeight: 2)
            let frame = PhotoFrame(width: photo.width, height: photo.height)
            let fit = fitPhoto(frame: frame, width: 600, height: 600)!
            XCTAssertEqual(pixels[orientation - 1].0, fit.x(points[orientation - 1].0), accuracy: 0.001)
            XCTAssertEqual(pixels[orientation - 1].1, fit.y(points[orientation - 1].1), accuracy: 0.001)
            XCTAssertTrue(progressMatchesPhoto(progress: ScanProgressState(token: 1, frame: frame), photo: photo))
        }
    }

    func test_photo_and_quads_share_the_same_integer_destination_at_every_aspect_ratio() {
        for frame in [PhotoFrame(width: 1281, height: 547), PhotoFrame(width: 547, height: 1281)] {
            for (width, height) in [(Float(359.5), Float(420)), (Float(800), Float(240))] {
                let fit = fitPhoto(frame: frame, width: width, height: height)!
                XCTAssertEqual(Float(fit.left), fit.x(0), accuracy: 0.001)
                XCTAssertEqual(Float(fit.left + fit.width), fit.x(Float(frame.width)), accuracy: 0.001)
                XCTAssertEqual(Float(fit.top), fit.y(0), accuracy: 0.001)
                XCTAssertEqual(Float(fit.top + fit.height), fit.y(Float(frame.height)), accuracy: 0.001)
                XCTAssertTrue(Float(fit.width) <= width + 1 && Float(fit.height) <= height + 1)
            }
        }
    }

    func test_replacement_and_unresolved_frames_cannot_draw_old_geometry() {
        let photo = ResolvedPhoto(source: PhotoInput.fromFile(bytes: Data([1])), orientation: 6, rawWidth: 640, rawHeight: 480)
        XCTAssertFalse(progressMatchesPhoto(progress: nil, photo: photo))
        XCTAssertFalse(progressMatchesPhoto(progress: ScanProgressState(token: 1), photo: photo))
        XCTAssertFalse(progressMatchesPhoto(progress: ScanProgressState(token: 1, frame: PhotoFrame(width: 640, height: 480)),
                                            photo: photo))
        XCTAssertTrue(progressMatchesPhoto(progress: ScanProgressState(token: 2, frame: PhotoFrame(width: 480, height: 640)),
                                           photo: photo))
        XCTAssertNil(fitPhoto(frame: PhotoFrame(width: 0, height: 10), width: 300, height: 300))
    }
}
