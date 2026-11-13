import AVFoundation
import Observation
import SwiftUI
import UIKit

/**
 * The back camera's session for the photo scanners: a preview fitted
 * whole into its view (CameraX's FIT_CENTER), a photo output with auto
 * flash, pinch to zoom and tap to focus. Explicit outputs only: no motion
 * reading overrides the preview's own rotation, which is the capture's.
 */
@Observable
final class DisplayCamera: @unchecked Sendable {
    /** The preview's view; its layer fits the capture into the view. */
    @ObservationIgnored let view = CameraPreviewView()
    @ObservationIgnored let capture = AVCapturePhotoOutput()
    @ObservationIgnored private let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "VisionCapture.session")
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var active = false

    /** The bound camera, once the session runs; Kotlin's `camera`. */
    private(set) var camera: AVCaptureDevice?
    private(set) var error: String?

    init() {
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.onPinch = { [weak self] scale in self?.zoom(by: scale) }
        view.onTap = { [weak self] point in self?.focus(at: point) }
    }

    func bind() {
        active = true
        queue.async { [self] in
            guard active else { return }
            do {
                if !configured { try configure() }
                if !session.isRunning { session.startRunning() }
                let device = self.device
                DispatchQueue.main.async { [self] in
                    guard active else { return }
                    if let device, rotation == nil {
                        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: view.previewLayer)
                    }
                    camera = device
                    error = nil
                }
            } catch {
                DispatchQueue.main.async { [self] in
                    camera = nil
                    self.error = "The camera could not start. Go back and try again."
                }
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraUnavailable()
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(capture) else { throw CameraUnavailable() }
        session.addInput(input)
        session.addOutput(capture)
        capture.maxPhotoQualityPrioritization = .quality
        self.device = device
        configured = true
    }

    private struct CameraUnavailable: Error {}

    /** Snapshot in the same Main turn as the capture request, never at callback time. */
    func shutterPreview() -> CapturePreviewMetadata {
        let frame = view.frame
        return CapturePreviewMetadata(
            bounds: CaptureBounds(left: Int(frame.minX), top: Int(frame.minY), right: Int(frame.maxX), bottom: Int(frame.maxY)),
            scaleType: "resizeAspect",
            layoutDirection: view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 : 0
        )
    }

    /**
     * Keep the existing rotation authority: the photo is turned as the preview
     * is, which is the app's own (portrait) orientation, never the phone's
     * attitude. Returns the rotation, in degrees, set on the photo connection.
     */
    func shutterRotation() throws -> CGFloat {
        guard camera != nil, let rotation else { throw CameraUnavailable() }
        let angle = rotation.videoRotationAngleForHorizonLevelPreview
        if let connection = capture.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        return angle
    }

    /** The photo settings for one shot: flash when the scene needs it. */
    func photoSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        if capture.supportedFlashModes.contains(.auto) { settings.flashMode = .auto }
        settings.photoQualityPrioritization = .quality
        return settings
    }

    private func zoom(by scale: CGFloat) {
        guard let device = camera else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let next = device.videoZoomFactor * scale
                device.videoZoomFactor = min(max(next, device.minAvailableVideoZoomFactor),
                                             device.maxAvailableVideoZoomFactor)
            } catch {}
        }
    }

    private func focus(at point: CGPoint) {
        guard let device = camera else { return }
        let layer = view.previewLayer
        let image = layer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        if !isInPreviewImage(image: image, x: point.x, y: point.y) { return }
        let target = layer.captureDevicePointConverted(fromLayerPoint: point)
        if !(0...1).contains(target.x) || !(0...1).contains(target.y) { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = target
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = target
                    device.exposureMode = .autoExpose
                }
            } catch {}
        }
    }

    func close() {
        active = false
        camera = nil
        rotation = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

/** The preview maps its normalized image rectangle to the actual visible image, including letterboxing. */
func isInPreviewImage(image: CGRect?, x: CGFloat, y: CGFloat) -> Bool {
    guard let image, x.isFinite, y.isFinite, !image.isNull, !image.isEmpty else { return false }
    return x >= image.minX && x <= image.maxX && y >= image.minY && y <= image.maxY
}

/** A view backed by the preview layer, with the camera's two gestures. */
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onPinch: ((CGFloat) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    private var pinching = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            pinching = true
            onPinch?(gesture.scale)
            gesture.scale = 1
        default:
            pinching = false
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if pinching { return }
        onTap?(gesture.location(in: self))
    }
}

/** The preview in SwiftUI: the session's own view, never a copy. */
struct CameraPreview: UIViewRepresentable {
    let view: CameraPreviewView

    func makeUIView(context: Context) -> CameraPreviewView { view }
    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
}
