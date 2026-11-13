import SwiftUI

struct AddWalletScreen: View {
    let onNewKey: () -> Void
    let onScanPhrase: () -> Void
    let onScanStrips: () -> Void
    let onBack: () -> Void

    var body: some View {
        WalletPage(title: "Add a wallet", onBack: onBack) {
            Text("Start fresh").font(.titleMedium)
            Button("Create a new wallet", action: onNewKey)
                .buttonStyle(.primary)
                .accessibilityIdentifier("new-key")
            Text("Already on paper").font(.titleMedium)
            WalletCard(fill: Palette.surface, outlined: true) {
                WalletLink(title: "Scan a written phrase", tag: "scan-phrase", onClick: onScanPhrase)
                    .padding(.horizontal, 16)
                WalletLink(title: "Scan two share strips", tag: "scan-strips", onClick: onScanStrips)
                    .padding(.horizontal, 16)
            }
        }
    }
}
