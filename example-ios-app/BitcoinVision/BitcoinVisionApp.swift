import SwiftUI

@main
struct BitcoinVisionApp: App {
    /** A PSBT the system handed in, until the app takes it. */
    @State private var incoming: Data?
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            AppRoot(incoming: $incoming)
                .overlay { privacyCover }
                // "Open in…" from Files, Mail or a wallet: a PSBT file, or text holding one.
                .onOpenURL { url in
                    if let bytes = Self.read(url) { incoming = bytes }
                }
        }
    }

    /**
     * The phrase must never reach the app switcher's snapshot. Release builds
     * cover the window whenever the scene is not active; debug builds stay
     * visible so the simulator can screenshot the flow.
     */
    @ViewBuilder
    private var privacyCover: some View {
        #if !DEBUG
        if phase != .active {
            Palette.background.ignoresSafeArea()
        }
        #endif
    }

    private static func read(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}
