import SwiftUI

/** The destination is a task label, never the pending request or key itself. */
struct LoadKeyScreen: View {
    let wallets: WalletsViewModel
    let id: String
    let task: String
    let onBack: () -> Void
    let onScanPhrase: () -> Void
    let onScanStrips: () -> Void

    var body: some View {
        if let wallet = wallets.wallet(id: id) {
            WalletPage(title: "Load key", onBack: onBack, titleTag: "load-title") {
                Text(wallet.name).font(.titleLarge)
                Text(wallet.fingerprint).font(Typeface.mono(14, relativeTo: .callout))
                Text("Key not loaded").accessibilityIdentifier("key-status")
                Text(purpose)
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .accessibilityIdentifier("load-purpose")
                if let notice = wallets.notice, notice.walletId == id {
                    Text(notice.text)
                        .foregroundStyle(Palette.error)
                        .accessibilityIdentifier("notice")
                }
                Button("Scan a written phrase", action: onScanPhrase)
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("scan-phrase")
                Button("Scan two share strips", action: onScanStrips)
                    .buttonStyle(.outlined)
                    .accessibilityIdentifier("scan-strips")
            }
        } else {
            Color.clear.onAppear { onBack() }
        }
    }

    private var purpose: String {
        switch task {
        case "sign": return "After loading, you return to the review and tap Sign."
        case "backup": return "After loading, you write a new set of three strips."
        default: return "From your written phrase or any two strips."
        }
    }
}
