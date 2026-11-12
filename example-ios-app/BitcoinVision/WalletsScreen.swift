import SwiftUI

/** The one place the app states its safety promise, so no other screen has to. */
let SAFETY_LINE = "Keys are held in memory only. This phone never saves recovery words."

struct WalletsScreen: View {
    let wallets: WalletsViewModel
    let onAdd: () -> Void
    let onOpen: (String) -> Void

    var body: some View {
        WalletPage(title: "Wallets", actions: { EmptyView() }, floatingAction: {
            if !wallets.wallets.isEmpty {
                Button(action: onAdd) {
                    Label("Add wallet", systemImage: "plus")
                        .font(.labelLarge)
                        .padding(.horizontal, 20)
                        .frame(height: 56)
                        .foregroundStyle(Palette.onPrimaryContainer)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.primaryContainer))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("add-wallet")
            }
        }) {
            if wallets.wallets.isEmpty {
                Text("Your wallet, on paper").font(.headlineSmall)
                Text("Create one, or scan one from paper.").accessibilityIdentifier("empty")
                Button("Add a wallet", action: onAdd)
                    .buttonStyle(.primary)
                    .fixedSize()
                    .accessibilityIdentifier("add-wallet")
            } else {
                WalletCard(fill: Palette.surface, outlined: true) {
                    ForEach(Array(wallets.wallets.enumerated()), id: \.element.id) { i, wallet in
                        let loaded = wallets.key(id: wallet.id) != nil
                        Button { onOpen(wallet.id) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "wallet.bifold.fill")
                                    .foregroundStyle(Palette.onSurfaceVariant)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(wallet.name).font(.bodyLarge).foregroundStyle(Palette.onSurface)
                                    Text("\(wallet.fingerprint) · \(loaded ? "key loaded" : "key not loaded")")
                                        .font(Typeface.mono(14, relativeTo: .callout))
                                        .foregroundStyle(Palette.onSurfaceVariant)
                                        .accessibilityIdentifier("wallet-\(i)-status")
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wallet-\(i)")
                    }
                }
                Spacer().frame(height: 80)
            }
            Text(SAFETY_LINE).font(.bodySmall).foregroundStyle(Palette.onSurfaceVariant)
        }
    }
}

/** Material's Card: a rounded container for a group of rows or a block of text. */
struct WalletCard<Content: View>: View {
    var fill: Color = Palette.surfaceContainerHighest
    /** Rows on the page's surface keep the card's edge as a hairline. */
    var outlined = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.outlineVariant, lineWidth: outlined ? 1 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
