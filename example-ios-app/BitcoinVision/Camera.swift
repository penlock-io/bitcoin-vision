import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/**
 * The camera step every photo scanner shares: the permission gate, the
 * preview, a bar over it with a back button and [bar]'s content, the
 * shutter and [overlay] on top. A tap on the shutter names a new
 * attempt through [onShutter] before the picture is taken, and the
 * camera's photo comes back through [onJpeg] with that name, nil
 * when the camera delivered nothing; what is done with it, and the
 * screen that shows it being read, is the caller's.
 */
struct CameraCapture<Bar: View, Overlay: View, Instead: View>: View {
    let shutterEnabled: Bool
    let onShutter: () -> Int
    let onJpeg: (Int, PhotoInput?) -> Void
    let onExit: () -> Void
    @ViewBuilder let bar: () -> Bar
    @ViewBuilder let overlay: () -> Overlay
    @ViewBuilder let instead: () -> Instead

    @Environment(\.scenePhase) private var scenePhase
    @State private var granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    init(
        shutterEnabled: Bool,
        onShutter: @escaping () -> Int,
        onJpeg: @escaping (Int, PhotoInput?) -> Void,
        onExit: @escaping () -> Void,
        @ViewBuilder bar: @escaping () -> Bar,
        @ViewBuilder overlay: @escaping () -> Overlay,
        @ViewBuilder instead: @escaping () -> Instead
    ) {
        self.shutterEnabled = shutterEnabled
        self.onShutter = onShutter
        self.onJpeg = onJpeg
        self.onExit = onExit
        self.bar = bar
        self.overlay = overlay
        self.instead = instead
    }

    var body: some View {
        Group {
            if granted {
                CameraSurface(shutterEnabled: shutterEnabled, onShutter: onShutter, onJpeg: onJpeg, onExit: onExit,
                              bar: bar, overlay: overlay)
            } else {
                permissionGate
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { await request() }
        }
        // Granting from the Settings app happens outside the request; coming back must notice it.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
        }
    }

    private func request() async {
        granted = await AVCaptureDevice.requestAccess(for: .video)
    }

    private var permissionGate: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("The camera reads what is on paper.")
                    .font(.bodyLarge)
                    .multilineTextAlignment(.center)
                Button("Allow camera") {
                    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                        Task { await request() }
                    } else {
                        openSettings()
                    }
                }
                .buttonStyle(.primary)
                instead()
                // After a refusal iOS stops asking; the Settings app is the only way back in.
                Button("Open app settings", action: openSettings).buttonStyle(.secondary)
                Button("Back", action: onExit).buttonStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height * 0.8)
        }
        .background(Palette.surface.ignoresSafeArea())
        .foregroundStyle(Palette.onSurface)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

extension CameraCapture where Overlay == EmptyView, Instead == EmptyView {
    init(
        shutterEnabled: Bool,
        onShutter: @escaping () -> Int,
        onJpeg: @escaping (Int, PhotoInput?) -> Void,
        onExit: @escaping () -> Void,
        @ViewBuilder bar: @escaping () -> Bar
    ) {
        self.init(shutterEnabled: shutterEnabled, onShutter: onShutter, onJpeg: onJpeg, onExit: onExit,
                  bar: bar, overlay: { EmptyView() }, instead: { EmptyView() })
    }
}

extension CameraCapture where Instead == EmptyView {
    init(
        shutterEnabled: Bool,
        onShutter: @escaping () -> Int,
        onJpeg: @escaping (Int, PhotoInput?) -> Void,
        onExit: @escaping () -> Void,
        @ViewBuilder bar: @escaping () -> Bar,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.init(shutterEnabled: shutterEnabled, onShutter: onShutter, onJpeg: onJpeg, onExit: onExit,
                  bar: bar, overlay: overlay, instead: { EmptyView() })
    }
}

extension CameraCapture where Overlay == EmptyView {
    init(
        shutterEnabled: Bool,
        onShutter: @escaping () -> Int,
        onJpeg: @escaping (Int, PhotoInput?) -> Void,
        onExit: @escaping () -> Void,
        @ViewBuilder bar: @escaping () -> Bar,
        @ViewBuilder instead: @escaping () -> Instead
    ) {
        self.init(shutterEnabled: shutterEnabled, onShutter: onShutter, onJpeg: onJpeg, onExit: onExit,
                  bar: bar, overlay: { EmptyView() }, instead: instead)
    }
}

/** The granted camera: the session lives exactly as long as this view. */
private struct CameraSurface<Bar: View, Overlay: View>: View {
    let shutterEnabled: Bool
    let onShutter: () -> Int
    let onJpeg: (Int, PhotoInput?) -> Void
    let onExit: () -> Void
    let bar: () -> Bar
    let overlay: () -> Overlay

    // Created once, when the camera first shows: never again on each re-render.
    @State private var session: DisplayCamera?

    var body: some View {
        ZStack {
            if let session {
                CameraPreview(view: session.view)
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: onExit) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("back")
                    bar()
                }
                .padding(12)
                // The preview behind can be any brightness; the bar carries its own ground.
                .background(Palette.cameraScrim.ignoresSafeArea(edges: .top))
                Spacer(minLength: 0)
            }
            ZStack { overlay() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = session?.error {
                Text(error).foregroundStyle(.white).multilineTextAlignment(.center).padding(24)
            }
            VStack {
                Spacer()
                Button(action: shoot) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(enabled ? Palette.onPrimary : Palette.onSurface.opacity(0.38))
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(enabled ? Palette.primary : Palette.onSurface.opacity(0.12)))
                }
                .disabled(!enabled)
                .accessibilityLabel("Take photo")
                .accessibilityIdentifier("shutter")
                .padding(32)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            let camera = session ?? DisplayCamera()
            session = camera
            camera.bind()
        }
        .onDisappear { session?.close() }
    }

    private var enabled: Bool { shutterEnabled && session?.camera != nil }

    private func shoot() {
        // A tap before the camera finishes starting, or while a photo is
        // being read, is a shrug, not a crash.
        guard shutterEnabled else { return }
        let token = onShutter()
        do {
            guard let session else { throw CancellationError() }
            let rotation = try session.shutterRotation()
            let preview = session.shutterPreview()
            takePicture(session: session, rotation: rotation, preview: preview) { onJpeg(token, $0) }
        } catch {
            onJpeg(token, nil)
        }
    }
}

/** Kotlin's `ImageFormat.JPEG`, kept so the diagnostic metadata means the same on both platforms. */
private let JPEG_FORMAT = 256

private func takePicture(
    session: DisplayCamera,
    rotation: CGFloat,
    preview: CapturePreviewMetadata,
    onJpeg: @escaping (PhotoInput?) -> Void
) {
    let delegate = CaptureDelegate(rotation: rotation, preview: preview, onJpeg: onJpeg)
    session.capture.capturePhoto(with: session.photoSettings(), delegate: delegate)
}

/**
 * One photo's callbacks. AVFoundation holds its delegate only weakly, so
 * each delegate keeps itself until the photo (or its failure) is handed on;
 * only attempt delivery returns to Main.
 */
private final class CaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let rotation: CGFloat
    private let preview: CapturePreviewMetadata
    private let onJpeg: (PhotoInput?) -> Void
    private var keep: CaptureDelegate?
    private var photo: PhotoInput?

    init(rotation: CGFloat, preview: CapturePreviewMetadata, onJpeg: @escaping (PhotoInput?) -> Void) {
        self.rotation = rotation
        self.preview = preview
        self.onJpeg = onJpeg
        super.init()
        keep = self
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil { self.photo = copyCapturedPhoto(photo: photo, rotation: rotation, previewAtShutter: preview) }
        if let captured = self.photo { logPhotoInput(photo: captured) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let photo = error == nil ? self.photo : nil
        let deliver = onJpeg
        DispatchQueue.main.async { deliver(photo) }
        keep = nil
    }
}

/**
 * The capture as the scanners take it: the JPEG exactly as encoded, and
 * the capture's turn as metadata. AVFoundation writes the connection's
 * rotation as the JPEG's EXIF orientation where CameraX reports rotation
 * degrees; it is read back as degrees so both apps resolve it the same way.
 */
func copyCapturedPhoto(photo: AVCapturePhoto, rotation: CGFloat?, previewAtShutter: CapturePreviewMetadata? = nil)
    -> PhotoInput? {
    guard let jpeg = photo.fileDataRepresentation(), !jpeg.isEmpty else { return nil }
    let tag = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
    let dimensions = photo.resolvedSettings.photoDimensions
    guard let degrees = cameraRotationDegrees(exifOrientation: tag),
          CameraPhotoMetadata.isValid(rotationDegrees: degrees, width: Int(dimensions.width), height: Int(dimensions.height))
    else { return nil }
    let metadata = CameraPhotoMetadata(
        rotationDegrees: degrees, width: Int(dimensions.width), height: Int(dimensions.height), format: JPEG_FORMAT,
        // The app is portrait only: its display never turns.
        displayRotationAtShutter: 0,
        sensorToDisplayDegreesAtShutter: rotation.map { Int($0.rounded()) },
        cropRect: CaptureBounds(left: 0, top: 0, right: Int(dimensions.width), bottom: Int(dimensions.height)),
        previewAtShutter: previewAtShutter
    )
    return PhotoInput.ownCameraBytes(bytes: jpeg, metadata: metadata)
}

/**
 * The photograph just taken, while it is read and after a read that
 * failed: the photo as the scanner sees it, a progress bar under it
 * that promises nothing it cannot measure, and the way back to the
 * camera at once, without waiting for the read. With [error], the
 * read is over and the photo stays for the person to judge.
 */
struct CapturedPhotoScreen<Extra: View>: View {
    let title: String
    let photo: ResolvedPhoto?
    let error: String?
    let onRetake: () -> Void
    var progress: ScanProgressState? = nil
    var onProgressPresented: (Int, UInt64) -> Void = { _, _ in }
    var stripProgress: StripProgressState? = nil
    @ViewBuilder let extra: () -> Extra

    init(
        title: String,
        photo: ResolvedPhoto?,
        error: String?,
        onRetake: @escaping () -> Void,
        progress: ScanProgressState? = nil,
        onProgressPresented: @escaping (Int, UInt64) -> Void = { _, _ in },
        stripProgress: StripProgressState? = nil,
        @ViewBuilder extra: @escaping () -> Extra
    ) {
        self.title = title
        self.photo = photo
        self.error = error
        self.onRetake = onRetake
        self.progress = progress
        self.onProgressPresented = onProgressPresented
        self.stripProgress = stripProgress
        self.extra = extra
    }

    var body: some View {
        TaskPage(title: title, onBack: onRetake) {
            if error == nil {
                if let stripProgress {
                    StripProcessingIndicator(progress: stripProgress)
                } else {
                    ScanProcessingIndicator(progress: progress).id(progress?.token)
                }
                Button("Cancel and retake", action: onRetake)
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("cancel-retake")
            } else {
                Button("Retake", action: onRetake)
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("retake")
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    photoView
                    if let error {
                        Text(error)
                            .font(.bodyLarge)
                            .foregroundStyle(Palette.error)
                            .accessibilityIdentifier("read-error")
                        extra()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("captured")
            }
        }
    }

    @ViewBuilder private var photoView: some View {
        if let photo, let stripProgress, error == nil {
            StripPhoto(photo: photo, review: nil, progress: stripProgress, onPresented: {
                onProgressPresented(stripProgress.token, stripProgress.sequence)
            })
        } else if let photo, let progress, error == nil {
            ScanProgressPhoto(photo: photo, progress: progress, onPresented: {
                onProgressPresented(progress.token, progress.sequence)
            })
        } else if let photo {
            // The shell, the bar and the way back render at once; the
            // photo follows when a worker has decoded it, and a decode
            // still under way when the attempt goes is dropped with it.
            WithPhotoBitmap(photo) { bitmap in
                if let bitmap {
                    Image(decorative: bitmap, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .accessibilityLabel("The photo just taken")
                        .accessibilityIdentifier("captured-photo")
                }
            }
        }
        if photo == nil, error == nil, progress != nil || stripProgress != nil {
            // Preparation has no preview yet, but still needs an actual displayed frame.
            let sequence = stripProgress?.sequence ?? progress?.sequence
            Canvas { _, _ in
                if let stripProgress {
                    onProgressPresented(stripProgress.token, stripProgress.sequence)
                } else if let progress {
                    onProgressPresented(progress.token, progress.sequence)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .id(sequence)
            .accessibilityHidden(true)
        }
    }
}

extension CapturedPhotoScreen where Extra == EmptyView {
    init(
        title: String,
        photo: ResolvedPhoto?,
        error: String?,
        onRetake: @escaping () -> Void,
        progress: ScanProgressState? = nil,
        onProgressPresented: @escaping (Int, UInt64) -> Void = { _, _ in },
        stripProgress: StripProgressState? = nil
    ) {
        self.init(title: title, photo: photo, error: error, onRetake: onRetake, progress: progress,
                  onProgressPresented: onProgressPresented, stripProgress: stripProgress, extra: { EmptyView() })
    }
}

private struct StripProcessingIndicator: View {
    let progress: StripProgressState

    var body: some View {
        let part: Float = progress.total.flatMap { $0 > 0 ? Float(progress.completed) / Float($0) : nil } ?? 0.15
        let target = (Float(progress.phase.ordinal) + part) / 5
        let value = progress.finished ? 1 : min(max(target, 0.01), 0.99)
        ProgressView(value: Double(value))
            .tint(Palette.primary)
            .accessibilityIdentifier("reading-progress")
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(progress.label)
                .font(.bodyMedium)
                .accessibilityIdentifier("scan-phase")
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/** Keyed to the attempt by the caller (`.id(token)`): a new attempt starts a new meter. */
private struct ScanProcessingIndicator: View {
    let progress: ScanProgressState?
    @State private var meter = ScanProgressMeter(startMs: progressClockMs())

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            ProgressView(value: Double(meter.advance(state: progress, nowMs: progressClockMs())))
                .tint(Palette.primary)
                .accessibilityIdentifier("reading-progress")
                .accessibilityValue("Estimated scan progress")
        }
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(progress?.label ?? "Preparing to read")
                .font(.bodyMedium)
                .accessibilityIdentifier("scan-phase")
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
