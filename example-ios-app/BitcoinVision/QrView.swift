import SwiftUI

// Scanners want contrast, not the app's palette: ink on paper in every theme.
private let QrPaper = Color.white
private let QrInk = Color(red: 0x17 / 255, green: 0x18 / 255, blue: 0x1A / 255)
private let QUIET_ZONE = 4

/** Frames of an animated code; the rate frostsnap and Sparrow's own display use. */
let QR_FRAME_MS: UInt64 = 100

/** A code drawn edge to edge in a square, with its quiet zone. */
struct QrView: View {
    let modules: QrModules
    let description: String

    var body: some View {
        let n = Int(modules.size)
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(QrPaper))
            let cell = min(size.width, size.height) / CGFloat(n + 2 * QUIET_ZONE)
            // A hair of overlap keeps hairline gaps from appearing between modules at odd scales.
            let module = CGSize(width: cell + 0.5, height: cell + 0.5)
            var ink = Path()
            for y in 0..<n {
                for x in 0..<n where modules.dark[y * n + x] {
                    ink.addRect(CGRect(
                        origin: CGPoint(x: CGFloat(x + QUIET_ZONE) * cell, y: CGFloat(y + QUIET_ZONE) * cell),
                        size: module
                    ))
                }
            }
            context.fill(ink, with: .color(QrInk))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(description)
        .accessibilityAddTraits(.isImage)
    }
}

/** The encoder's parts shown in turn while the scene is active; a single part stays still. */
struct AnimatedQr: View {
    let encoder: PsbtQrEncoder
    let description: String

    @State private var modules: QrModules?
    @State private var shownFor: ObjectIdentifier?
    @Environment(\.scenePhase) private var phase

    private struct Run: Equatable {
        let encoder: ObjectIdentifier
        let resumed: Bool
    }

    var body: some View {
        Group {
            if let modules, shownFor == ObjectIdentifier(encoder) {
                QrView(modules: modules, description: description)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .task(id: Run(encoder: ObjectIdentifier(encoder), resumed: phase == .active)) {
            let id = ObjectIdentifier(encoder)
            if shownFor != id {
                modules = try? qrModules(text: encoder.nextPart())
                shownFor = id
            }
            guard phase == .active, encoder.partCount() > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: QR_FRAME_MS * 1_000_000)
                if Task.isCancelled { break }
                if let next = try? qrModules(text: encoder.nextPart()) { modules = next }
            }
        }
    }
}

/** A static code for `text`, or nothing when it is too long for one. */
struct StaticQr: View {
    let text: String
    let description: String
    let tag: String

    var body: some View {
        if let modules = try? qrModules(text: text) {
            QrView(modules: modules, description: description)
                .accessibilityIdentifier(tag)
        }
    }
}
