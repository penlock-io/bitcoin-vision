import SwiftUI

/** Canonical photo coordinates from the native strip and production cell windows. */
struct StripPhoto: View {
    let photo: ResolvedPhoto
    let review: StripReview?
    var progress: StripProgressState? = nil
    /** A decoded preview to draw; nil decodes [photo] off Main, as Kotlin's `rememberPhotoBitmap`. */
    var bitmap: CGImage? = nil
    var onPresented: () -> Void = {}

    var body: some View {
        if let bitmap {
            presented(bitmap)
        } else {
            WithPhotoBitmap(photo) { image in
                if let image { presented(image) }
            }
        }
    }

    private func presented(_ image: CGImage) -> some View {
        canvas(image)
            .onAppear(perform: onPresented)
            .onChange(of: progress?.sequence) { onPresented() }
    }

    private func canvas(_ image: CGImage) -> some View {
        let frame = PhotoFrame(width: photo.width, height: photo.height)
        let review = self.review
        let progress = self.progress
        return Color.clear
            .aspectRatio(CGFloat(photo.width) / CGFloat(photo.height), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 420)
            .overlay {
                Canvas { context, size in
                    guard let fit = fitPhoto(frame: frame, width: Float(size.width), height: Float(size.height))
                    else { return }
                    context.draw(Image(decorative: image, scale: 1), in: fit.rect)
                    func outline(_ corners: [Float], _ colour: Color, _ width: CGFloat) {
                        if corners.count != 8 || corners.contains(where: { !$0.isFinite }) { return }
                        var path = Path()
                        for i in 0..<4 {
                            let point = CGPoint(x: CGFloat(fit.x(corners[2 * i])), y: CGFloat(fit.y(corners[2 * i + 1])))
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        path.closeSubpath()
                        context.stroke(path, with: .color(Palette.surface.opacity(0.85)), lineWidth: width + 2)
                        context.stroke(path, with: .color(colour), lineWidth: width)
                    }
                    if let review {
                        outline(review.corners, Palette.primary, 2.5)
                        for row in review.rows {
                            for cell in row.cells {
                                let colour: Color
                                if cell.unread && cell.replacement == nil { colour = Palette.error }
                                else if cell.replacement != nil { colour = Palette.secondary } // Material's tertiary
                                else if (cell.probability ?? 0) < 0.75 { colour = Palette.error }
                                else { colour = Palette.primary.opacity(0.75) }
                                outline(cell.corners, colour, 1)
                            }
                        }
                    } else if let progress, progress.frame == frame {
                        for region in progress.regions.values {
                            outline(region.corners, region.read ? Palette.primary : Palette.onSurfaceVariant,
                                    region.read ? 2 : 1.5)
                        }
                    }
                }
            }
            .background(Palette.surfaceContainer)
            .accessibilityElement()
            .accessibilityLabel("Photographed strip and cell windows")
            .accessibilityIdentifier("captured-photo")
    }
}

struct StripProgressPhoto: View {
    let photo: ResolvedPhoto
    let progress: StripProgressState
    let onPresented: () -> Void

    var body: some View {
        StripPhoto(photo: photo, review: nil, progress: progress, onPresented: onPresented)
    }
}
