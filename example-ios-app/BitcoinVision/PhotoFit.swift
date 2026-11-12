import Foundation

/** The exact integer image destination and its matching full-image coordinate map. */
struct PhotoFit: Equatable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let frame: PhotoFrame

    func x(_ value: Float) -> Float { Float(left) + value * Float(width) / Float(frame.width) }
    func y(_ value: Float) -> Float { Float(top) + value * Float(height) / Float(frame.height) }
    func x(value: Float) -> Float { x(value) }
    func y(value: Float) -> Float { y(value) }

    /** The destination as a drawing rectangle. */
    var rect: CGRect { CGRect(x: left, y: top, width: width, height: height) }
}

/** Kotlin's `Float.roundToInt()`: halves round up, as `Math.round` does. */
private func roundToInt(_ value: Float) -> Int { Int((value + 0.5).rounded(.down)) }

/** Canonical coordinates only: this function never reads or reapplies orientation. */
func fitPhoto(frame: PhotoFrame, width: Float, height: Float) -> PhotoFit? {
    if frame.width <= 0 || frame.height <= 0 || !width.isFinite || !height.isFinite || width < 1 || height < 1 {
        return nil
    }
    let scale = min(width / Float(frame.width), height / Float(frame.height))
    let drawnWidth = max(roundToInt(Float(frame.width) * scale), 1)
    let drawnHeight = max(roundToInt(Float(frame.height) * scale), 1)
    return PhotoFit(left: roundToInt((width - Float(drawnWidth)) / 2), top: roundToInt((height - Float(drawnHeight)) / 2),
                    width: drawnWidth, height: drawnHeight, frame: frame)
}

func progressMatchesPhoto(progress: ScanProgressState?, photo: ResolvedPhoto) -> Bool {
    guard let progress else { return false }
    return progress.frame == PhotoFrame(width: photo.width, height: photo.height) &&
        !progress.overlaysDisabled && !progress.unavailable
}
