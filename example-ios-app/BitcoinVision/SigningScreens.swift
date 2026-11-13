import SwiftUI
import UIKit
import UniformTypeIdentifiers

/** Satoshis as the pages print them. */
func sats(n: UInt64) -> String {
    // Grouped by hand: a formatter would go through Double and could round large amounts.
    let digits = Array(String(n))
    var out = ""
    for (i, digit) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(digit)
    }
    return out + " sats"
}

/** Presentation only: validated outgoing outputs plus fee, never the input total. */
func totalLeaving(amounts: [UInt64], fee: UInt64) -> UInt64 {
    amounts.reduce(fee) { sum, amount in sum &+ amount }
}

/** Payload bytes per animated frame: what frostsnap shows Sparrow, comfortably read at arm's length. */
let QR_FRAGMENT_BYTES: UInt32 = 400

/**
 * The PSBT to sign, off Sparrow's screen or from the phone's files. (The
 * Android debug build's emulator-only "From file" route reads a directory
 * only adb can fill; it has no iOS counterpart.)
 */
struct SignPickScreen: View {
    let wallets: WalletsViewModel
    let onScanQr: () -> Void
    let onReviewed: () -> Void
    let onBack: () -> Void

    @State private var picking = false

    private func take(_ bytes: Data) {
        wallets.receive(bytes)
        onReviewed()
    }

    var body: some View {
        TaskPage(title: "Sign a transaction", onBack: onBack, actions: {
            Button("Scan QR code", action: onScanQr)
                .buttonStyle(.primary)
                .accessibilityIdentifier("scan-qr")
            Button("Choose transaction file") { picking = true }
                .buttonStyle(.outlined)
                .accessibilityIdentifier("choose-file")
        }) {
            SigningBody {
                Text("Show Sparrow's QR code to the camera.").font(.titleLarge)
                Text("Review first, then sign. Nothing is broadcast.").foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let bytes = try? Data(contentsOf: url) { take(bytes) }
        }
    }
}

/** Back keeps a pending request; Dismiss explicitly discards it. */
struct ReviewPsbtScreen: View {
    let wallets: WalletsViewModel
    let onSigned: () -> Void
    let onLoadKey: (String) -> Void
    let onChooseAnother: () -> Void
    let onBack: () -> Void
    let onDone: () -> Void

    var body: some View {
        switch wallets.signing {
        case nil:
            EndedSigning(onDone: onDone)
        case let .signed(walletId, review, _):
            // Keep the reviewed summary on the outgoing page during the signing transition.
            TaskPage(title: "Review transaction", onBack: onDone, actions: { EmptyView() }) {
                SigningBody {
                    SigningIdentity(name: wallets.wallet(id: walletId)?.name, review: review)
                    PaymentSummary(review: review)
                }
            }
        case let .refused(_, reason):
            TaskPage(title: "Not signed", onBack: onDone, actions: {
                Button("Choose another file", action: onChooseAnother)
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("choose-another")
                Button("Return", action: onDone)
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("done-signing")
            }) {
                SigningBody {
                    Text(reason)
                        .font(.titleMedium)
                        .foregroundStyle(Palette.error)
                        .accessibilityIdentifier("refusal")
                    Text("Nothing was signed.").foregroundStyle(Palette.onSurfaceVariant)
                }
            }
        case let .pending(walletId, review):
            let signing = Signing.pending(walletId: walletId, review: review)
            let loaded = wallets.key(id: walletId) != nil
            TaskPage(title: "Review transaction", onBack: onBack, actions: {
                if loaded {
                    // Capture the request drawn, not whatever is current when the tap lands.
                    Button("Sign transaction") { if wallets.sign(pending: signing) { onSigned() } }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("sign")
                } else {
                    Text("Load the key, then sign.")
                        .font(.bodyMedium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("key-missing")
                    Button("Load key") { onLoadKey(walletId) }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("load-key")
                }
                Button("Dismiss transaction", action: onDone)
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("dismiss")
            }) {
                SigningBody {
                    SigningIdentity(name: wallets.wallet(id: walletId)?.name, review: review)
                    PaymentSummary(review: review)
                }
            }
            .id(ObjectIdentifier(review))
        }
    }
}

private struct EndedSigning: View {
    let onDone: () -> Void

    var body: some View {
        TaskPage(title: "Transaction", onBack: onDone, actions: {
            Button("Return", action: onDone)
                .buttonStyle(.primary)
                .accessibilityIdentifier("done-signing")
        }) {
            SigningBody {
                Text("Nothing to sign").accessibilityIdentifier("signing-ended")
            }
        }
    }
}

private struct SigningBody<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }
}

private struct SigningIdentity: View {
    let name: String?
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name ?? "Wallet").font(.titleLarge).accessibilityIdentifier("sign-title")
            Text("Fingerprint \(review.fingerprint())")
                .font(Typeface.mono(14, relativeTo: .callout))
                .foregroundStyle(Palette.onSurfaceVariant)
        }
    }
}

private struct PaymentSummary: View {
    let review: Review

    @State private var details = false

    var body: some View {
        let leaving = review.leaving()
        Text("To recipients").font(.titleMedium)
        if leaving.isEmpty {
            Text("No recipient payments. Only the fee leaves this wallet.").accessibilityIdentifier("leaving-none")
        }
        ForEach(Array(leaving.enumerated()), id: \.offset) { i, line in
            WalletCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recipient \(i + 1)").font(.labelLarge)
                    Text(sats(n: line.amount))
                        .font(Typeface.mono(22, relativeTo: .title3))
                        .accessibilityIdentifier("leaving-\(i + 1)-amount")
                    Text(line.address)
                        .font(Typeface.mono(14, relativeTo: .callout))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("leaving-\(i + 1)-address")
                }
                .padding(16)
            }
        }
        AmountLine(label: "Network fee", value: sats(n: review.fee()), tag: "fee")
        Divider().overlay(Palette.outlineVariant)
        VStack(alignment: .leading, spacing: 4) {
            Text("Total leaving this wallet").font(.titleMedium)
            Text(sats(n: totalLeaving(amounts: leaving.map(\.amount), fee: review.fee())))
                .font(Typeface.mono(28, relativeTo: .title))
                .accessibilityIdentifier("total-leaving")
            Text("Recipient payments + network fee")
                .font(.bodySmall)
                .foregroundStyle(Palette.onSurfaceVariant)
        }
        Button(details ? "Hide transaction details" : "Transaction details") { details.toggle() }
            .buttonStyle(.secondary)
            .accessibilityValue(details ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("transaction-details")
        if details {
            AmountLine(label: "Change back to this wallet", value: sats(n: review.change()), tag: "change")
            AmountLine(label: "Input total from this wallet", value: sats(n: review.inputsTotal()), tag: "inputs-total")
        }
    }
}

/** Stacked values keep large amounts readable at increased font sizes. */
private struct AmountLine: View {
    let label: String
    let value: String
    let tag: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.bodyMedium).foregroundStyle(Palette.onSurfaceVariant)
            Text(value).font(Typeface.mono(16, relativeTo: .headline)).accessibilityIdentifier(tag)
        }
    }
}

/** Signed locally: export is a hand-off, never a broadcast-success claim. */
struct SignedScreen: View {
    let wallets: WalletsViewModel
    let onDone: () -> Void

    @State private var snackbar = SnackbarState()
    @State private var encoder: PsbtQrEncoder?
    @State private var encoded: Data?

    var body: some View {
        if case let .signed(walletId, review, bytes) = wallets.signing {
            let text = bytes.base64EncodedString()
            TaskPage(title: "Signed transaction", onBack: onDone, snackbar: snackbar, actions: {
                ShareLink(item: text, subject: Text("Signed transaction")) {
                    Text("Share signed transaction")
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("share-signed")
                Button("Copy") {
                    UIPasteboard.general.string = text
                    snackbar.show("Signed transaction copied")
                }
                .buttonStyle(.outlined)
                .accessibilityIdentifier("copy-signed")
                Button("Done", action: onDone)
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("done-signed")
            }) {
                SigningBody {
                    if let encoder, encoded == bytes {
                        AnimatedQr(encoder: encoder, description: "Signed transaction as a QR code")
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("signed-qr")
                    }
                    Text("Signed — not broadcast").font(.titleLarge).accessibilityIdentifier("signed")
                    Text("Scan it with Sparrow, or hand the file back, to broadcast.")
                        .foregroundStyle(Palette.onSurfaceVariant)
                    SigningIdentity(name: wallets.wallet(id: walletId)?.name, review: review)
                    PaymentSummary(review: review)
                }
            }
            .onChange(of: bytes, initial: true) { _, now in
                guard encoded != now else { return }
                encoder = try? psbtQrParts(psbt: now, maxFragmentLen: QR_FRAGMENT_BYTES)
                encoded = now
            }
        } else {
            EndedSigning(onDone: onDone)
        }
    }
}
