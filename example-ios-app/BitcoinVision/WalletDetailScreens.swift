import SwiftUI
import UIKit

extension KeySource {
    func description() -> String {
        switch self {
        case .new: return "Made on this phone."
        case .writtenPhrase: return "Loaded from your written phrase."
        case let .strips(first, second):
            return "Loaded from share strips \(min(first, second)) and \(max(first, second))."
        }
    }
}

struct ConnectWalletScreen: View {
    let wallets: WalletsViewModel
    let id: String
    let onBack: () -> Void

    @State private var snackbar = SnackbarState()

    var body: some View {
        if let wallet = wallets.wallet(id: id) {
            WalletPage(title: "Connect to Sparrow", onBack: onBack, snackbar: snackbar) {
                Text(wallet.name).font(.titleLarge)
                Text("Scan this in Sparrow to watch the wallet and build transactions for this phone to sign.")
                    .foregroundStyle(Palette.onSurfaceVariant)
                StaticQr(text: wallet.descriptor, description: "Descriptor of \(wallet.name) as a QR code", tag: "descriptor-qr")
                    .frame(maxWidth: .infinity)
                WalletCard {
                    Text(wallet.descriptor)
                        .font(Typeface.mono(14, relativeTo: .callout))
                        .textSelection(.enabled)
                        .padding(16)
                        .accessibilityIdentifier("descriptor")
                }
                ShareLink(item: wallet.descriptor, subject: Text("Descriptor of \(wallet.name)")) {
                    Text("Share descriptor")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("share-descriptor")
                Button("Copy descriptor") {
                    UIPasteboard.general.string = wallet.descriptor
                    snackbar.show("Descriptor copied")
                }
                .buttonStyle(.outlined)
                .accessibilityIdentifier("copy-descriptor")
            }
        } else {
            Color.clear.onAppear { onBack() }
        }
    }
}

struct KeyControlsScreen: View {
    let wallets: WalletsViewModel
    let id: String
    let onBack: () -> Void
    let onLoadKey: () -> Void

    @State private var confirmUnload = false

    var body: some View {
        if let wallet = wallets.wallet(id: id) {
            page(wallet)
                // Revealing is local to this visit, never restored from saved state.
                .onDisappear {
                    if wallets.revealed == id { wallets.revealed = nil }
                }
                .modifier(UnloadWarningDialog(
                    isPresented: $confirmUnload,
                    onKeep: { confirmUnload = false },
                    onUnload: {
                        wallets.unload(id: id)
                        confirmUnload = false
                    }
                ))
        } else {
            Color.clear.onAppear { onBack() }
        }
    }

    @ViewBuilder
    private func page(_ wallet: WalletRecord) -> some View {
        let key = wallets.key(id: id)
        WalletPage(title: "Key controls", onBack: onBack) {
            Text(wallet.name).font(.titleLarge)
            Text(wallet.fingerprint).font(Typeface.mono(14, relativeTo: .callout))
            Text(key == nil ? "Key not loaded" : "Key loaded")
                .font(.titleMedium)
                .accessibilityIdentifier("key-status")
            if let key {
                Text(key.source.description()).foregroundStyle(Palette.onSurfaceVariant)
                if wallets.needsBackupWarning(id: id) {
                    Text("No paper backup yet.").foregroundStyle(Palette.onSurfaceVariant)
                }
                let shown = wallets.revealed == id
                Button(shown ? "Hide the phrase" : "Show the phrase") {
                    wallets.revealed = shown ? nil : id
                }
                .buttonStyle(.outlined)
                .accessibilityIdentifier("show-phrase")
                if shown {
                    Text("Keep the screen private.").font(.labelLarge)
                    PhraseBody(words: key.words)
                }
                Button("Unload the key") {
                    if wallets.needsBackupWarning(id: id) { confirmUnload = true } else { wallets.unload(id: id) }
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier("unload")
            } else {
                Button("Load key", action: onLoadKey)
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("load-controls-key")
            }
        }
    }
}

struct PhraseBody: View {
    let words: [String]

    var body: some View {
        let half = (words.count + 1) / 2
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<2, id: \.self) { column in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(stride(from: column * half, to: min((column + 1) * half, words.count), by: 1)), id: \.self) { i in
                        Text("\(i + 1). \(words[i])")
                            .font(Typeface.mono(22, relativeTo: .title3))
                            .accessibilityIdentifier("word-\(i + 1)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}
