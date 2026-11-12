import AVFoundation
import SwiftUI
import UIKit

/**
 * The viewfinder that reads a PSBT off a screen: single or animated
 * `ur:crypto-psbt`, with a ring for the animated kind. `onPsbt` fires
 * once per visit, on the main thread, and never after the person has
 * left: the session is retired before Back navigates, when the scene
 * stops being active (another PSBT arriving, the app going behind), and
 * on disappearance as the fallback.
 */
struct QrScanScreen: View {
    let title: String
    let onPsbt: (Data) -> Void
    let onExit: () -> Void

    var body: some View {
        QrCameraPermissionGate(onExit: onExit) {
            QrScanner(title: title, onPsbt: onPsbt, onExit: onExit)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/** The scanning session of one visit; a paused page's session is spent, and coming back starts a fresh one. */
@Observable @MainActor
private final class QrScanModel {
    private(set) var state = QrScanState()
    /** The controller the camera thread hands frames to. */
    @ObservationIgnored let slot = ControllerSlot()
    @ObservationIgnored var deliver: (Data) -> Void = { _ in }
    @ObservationIgnored private var controller: QrScanController?

    var retired: Bool { controller?.retired ?? true }

    /** A new generation: a fresh decoder, controller and ring. */
    func renew() {
        controller?.retire()
        state = QrScanState()
        let fresh = Self.makeController { [weak self] scan in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state = self.state.after(scan: scan)
                if case let .decoded(psbt) = scan { self.deliver(psbt) }
            }
        }
        controller = fresh
        slot.set(fresh)
    }

    func retire() {
        controller?.retire()
    }

    /** Built outside the main actor: decode and release run on the camera thread. */
    nonisolated private static func makeController(onScan: @escaping (QrScan) -> Void) -> QrScanController {
        let decoder = DecoderBox()
        return QrScanController(
            decode: { @Sendable frame in
                guard let native = decoder.decoder else { throw DecoderBox.Gone() }
                return native.feedLuma(
                    width: UInt32(frame.width), height: UInt32(frame.height),
                    rowStride: UInt32(frame.rowStride), luma: frame.luma
                )
            },
            release: { @Sendable in decoder.decoder = nil },
            post: { work in DispatchQueue.main.async(execute: work) },
            onScan: onScan
        )
    }
}

/** The native decoder until its controller releases it. */
private final class DecoderBox: @unchecked Sendable {
    struct Gone: Error {}
    private let lock = NSLock()
    private var held: PsbtQrDecoder? = PsbtQrDecoder()

    var decoder: PsbtQrDecoder? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/** The current controller, read from the camera thread. */
private final class ControllerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current: QrScanController?

    func set(_ controller: QrScanController) { lock.withLock { current = controller } }

    func offer(_ frame: QrFrame) {
        let controller = lock.withLock { current }
        controller?.offer(frame: frame)
    }
}

private struct QrScanner: View {
    let title: String
    let onPsbt: (Data) -> Void
    let onExit: () -> Void

    @State private var model = QrScanModel()
    @State private var session = QrCameraSession()
    @Environment(\.scenePhase) private var phase

    private func exit() {
        model.retire()
        onExit()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QrPreview(session: session.capture)
                .ignoresSafeArea()
                .accessibilityIdentifier("qr-preview")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: exit) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("back")
                    Text(title).font(.titleMedium).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Palette.cameraScrim.ignoresSafeArea(edges: .top))
                Spacer(minLength: 0)
                ScanRing(state: model.state)
                    .padding(32)
            }
            if let error = session.error {
                Text(error).foregroundStyle(.white).multilineTextAlignment(.center).padding(24)
            }
        }
        .onAppear {
            model.deliver = onPsbt
            if model.retired { model.renew() }
            let slot = model.slot
            session.start { @Sendable frame in slot.offer(frame) }
        }
        .onDisappear {
            model.retire()
            session.close()
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .active: if model.retired { model.renew() }
            default: model.retire()
            }
        }
    }
}

private struct ScanRing: View {
    let state: QrScanState

    var body: some View {
        VStack(spacing: 12) {
            if state.partsExpected > 0 {
                ZStack {
                    Circle().stroke(Palette.cameraScrim, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(state.fraction))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 72, height: 72)
                .accessibilityElement()
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int(state.fraction * 100)) percent")
                .accessibilityIdentifier("qr-progress")
                Text("\(state.partsSeen) of \(state.partsExpected) parts")
                    .font(Typeface.mono(14, relativeTo: .subheadline))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("qr-parts")
            }
            if let notice = state.notice {
                Text(notice)
                    .font(.bodyMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.cameraScrim)
                    .accessibilityIdentifier("qr-notice")
            }
        }
        // The notice is a polite live region on Android.
        .onChange(of: state.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
    }
}

// The same gate the photo camera carries inline; the two could fold together.
private struct QrCameraPermissionGate<Content: View>: View {
    let onExit: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @Environment(\.scenePhase) private var phase

    private func request() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { status = AVCaptureDevice.authorizationStatus(for: .video) }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    var body: some View {
        Group {
            if status == .authorized {
                content()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        Text("The camera reads the code on Sparrow's screen.")
                            .font(.bodyLarge)
                            .multilineTextAlignment(.center)
                        // iOS asks once; after a refusal only Settings can grant it.
                        Button("Allow camera") {
                            if status == .notDetermined { request() } else { openSettings() }
                        }
                        .buttonStyle(.primary)
                        Button("Open app settings", action: openSettings).buttonStyle(.secondary)
                        Button("Back", action: onExit).buttonStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical, alignment: .center)
                }
                .foregroundStyle(Palette.onSurface)
                .background(Palette.surface.ignoresSafeArea())
            }
        }
        .task { if status == .notDetermined { request() } }
        .onChange(of: phase) { _, now in
            if now == .active { status = AVCaptureDevice.authorizationStatus(for: .video) }
        }
    }
}

/** Preview plus analysis on the back camera. */
@Observable
final class QrCameraSession {
    private(set) var error: String?
    @ObservationIgnored let capture = AVCaptureSession()
    @ObservationIgnored private let output = AVCaptureVideoDataOutput()
    @ObservationIgnored private let frames = DispatchQueue(label: "VisionQr")
    @ObservationIgnored private let control = DispatchQueue(label: "VisionQrSession")
    @ObservationIgnored private var delegate: QrFrameDelegate?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var active = false

    func start(onFrame: @escaping @Sendable (QrFrame) -> Void) {
        active = true
        let delegate = QrFrameDelegate(onFrame: onFrame)
        self.delegate = delegate
        // Only the latest frame is kept; late ones are dropped, as CameraX's KEEP_ONLY_LATEST.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: frames)
        control.async { [self] in
            let ok = configure()
            if ok { capture.startRunning() }
            DispatchQueue.main.async { [self] in
                guard active else { return }
                error = ok ? nil : "The camera could not start. Go back and try again."
            }
        }
    }

    /** Runs on `control`. */
    private func configure() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
        guard capture.canAddInput(input) else { return false }
        capture.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        guard capture.canAddOutput(output) else { return false }
        capture.addOutput(output)
        configured = true
        return true
    }

    func close() {
        active = false
        output.setSampleBufferDelegate(nil, queue: nil)
        delegate = nil
        control.async { [capture] in capture.stopRunning() }
    }
}

/** Hands each frame's luma plane on; a malformed frame is a dropped frame. */
private final class QrFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let onFrame: @Sendable (QrFrame) -> Void

    init(onFrame: @escaping @Sendable (QrFrame) -> Void) {
        self.onFrame = onFrame
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let frame = buffer.lumaFrame() else { return }
        onFrame(frame)
    }
}

extension CVPixelBuffer {
    /** The Y plane, packed to one byte per pixel; nil when the buffer is not a luma-first planar one. */
    func lumaFrame() -> QrFrame? {
        guard CVPixelBufferIsPlanar(self), CVPixelBufferGetPlaneCount(self) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(self, 0)
        let height = CVPixelBufferGetHeightOfPlane(self, 0)
        let rowStride = CVPixelBufferGetBytesPerRowOfPlane(self, 0)
        guard width > 0, height > 0, rowStride >= width,
              let base = CVPixelBufferGetBaseAddressOfPlane(self, 0)
        else { return nil }
        var out = Data(count: width * height)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                dst.baseAddress!.advanced(by: y * width)
                    .copyMemory(from: base.advanced(by: y * rowStride), byteCount: width)
            }
        }
        return QrFrame(width: width, height: height, rowStride: width, luma: out)
    }
}

/** The camera's picture, fitted inside the view (CameraX's FIT_CENTER). */
private struct QrPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.preview.videoGravity = .resizeAspect
        view.preview.session = session
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.preview.session !== session { view.preview.session = session }
    }
}
