import SwiftUI

/** A closed outline through four corners, fitted onto the drawn photo. */
func photoQuadPath(_ corners: [Float], _ fit: PhotoFit, dx: Float = 0, dy: Float = 0) -> Path {
    var path = Path()
    for k in 0..<4 {
        let point = CGPoint(x: CGFloat(fit.x(corners[2 * k] - dx)), y: CGFloat(fit.y(corners[2 * k + 1] - dy)))
        if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/** No live labels or confidence colours: only geometry and native processing state. */
struct ScanProgressPhoto: View {
    let photo: ResolvedPhoto
    let progress: ScanProgressState
    var onPresented: () -> Void = {}

    // Kotlin divides the height limit by the font scale: larger text leaves less room for the photo.
    @ScaledMetric(relativeTo: .body) private var scaledLimit: CGFloat = 420
    @State private var width: CGFloat = 0

    init(photo: ResolvedPhoto, progress: ScanProgressState, onPresented: @escaping () -> Void = {}) {
        self.photo = photo
        self.progress = progress
        self.onPresented = onPresented
    }

    var body: some View {
        WithPhotoBitmap(photo) { bitmap in
            if let bitmap { canvas(bitmap) } // Never draw boxes over a missing or previous preview.
        }
    }

    private func canvas(_ image: CGImage) -> some View {
        let limit = 420 * 420 / max(scaledLimit, 420)
        let height = min(limit, width * CGFloat(photo.height) / CGFloat(photo.width))
        return Canvas { context, size in
            guard let fit = fitPhoto(frame: PhotoFrame(width: photo.width, height: photo.height),
                                     width: Float(size.width), height: Float(size.height)) else { return }
            context.draw(Image(decorative: image, scale: 1), in: fit.rect)
            let matches = progressMatchesPhoto(progress: progress, photo: photo)
            if matches, let card = progress.card {
                let outline = photoQuadPath(card, fit)
                context.stroke(outline, with: .color(Palette.surface.opacity(0.9)), lineWidth: 5)
                context.stroke(outline, with: .color(Palette.primary), lineWidth: 3)
            }
            if matches {
                for region in progress.regions.values {
                    if region.state == .excluded { continue }
                    let path = photoQuadPath(region.corners, fit)
                    let reading = region.state == .reading
                    let read = region.state == .read
                    let lineWidth: CGFloat = reading ? 3 : 1.5
                    let dash: [CGFloat] = region.state == .found ? [6, 4] : []
                    if read { context.fill(path, with: .color(Palette.primary.opacity(0.12))) }
                    // A surface halo remains visible on light or dark paper. Stronger
                    // double outline / dashed / filled shapes also work without colour.
                    context.stroke(path, with: .color(Palette.surface.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: lineWidth + 2, dash: dash))
                    context.stroke(path, with: .color(reading || read ? Palette.primary : Palette.onSurfaceVariant),
                                   style: StrokeStyle(lineWidth: lineWidth, dash: dash))
                }
            }
            // Only acknowledge after the preview and this snapshot's boxes were drawn.
            onPresented()
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Palette.surfaceContainer)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement()
        .accessibilityLabel("The photo just taken")
        .accessibilityIdentifier("captured-photo")
    }
}
