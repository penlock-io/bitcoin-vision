import SwiftUI
import UIKit

func prettyDate(iso: String) -> String {
    let parse = DateFormatter()
    parse.calendar = Calendar(identifier: .gregorian)
    parse.locale = Locale(identifier: "en_US_POSIX")
    parse.timeZone = TimeZone(identifier: "UTC")
    parse.dateFormat = "yyyy-MM-dd"
    guard let date = parse.date(from: iso) else { return iso }
    let format = DateFormatter()
    format.calendar = Calendar(identifier: .gregorian)
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "d MMM yyyy"
    return format.string(from: date)
}

/** The one button under the key card, and where it goes. */
enum Primary: CaseIterable, Equatable, Hashable {
    case review, backUp, sign, scan

    var label: String {
        switch self {
        case .review: return "Review transaction"
        case .backUp: return "Back up this wallet"
        case .sign: return "Sign a transaction"
        case .scan: return "Scan phrase"
        }
    }

    var tag: String {
        switch self {
        case .review: return "review-waiting"
        case .backUp: return "back-up"
        case .sign: return "sign-transaction"
        case .scan: return "load-wallet-key"
        }
    }
}

/** Pending review outranks everything; a fresh key asks to be backed up; then sign or scan. */
func primaryFor(next: WalletAction) -> Primary {
    switch next {
    case .review: return .review
    case .backUp: return .backUp
    case .sign: return .sign
    case .loadKey: return .scan
    }
}

extension KeySource {
    func provenance() -> String {
        switch self {
        case .new: return "made on this phone"
        case .writtenPhrase: return "from written phrase"
        case let .strips(first, second): return "from strips \(min(first, second)) and \(max(first, second))"
        }
    }
}

func backupLabel(checked: String?) -> String {
    checked.map { "Backup checked \(prettyDate(iso: $0))" } ?? "Backup not checked"
}

/** A swipe counts only when the card has travelled almost its whole width. */
let UNLOAD_TRAVEL: Float = 0.9

/**
 * Whether a release at `offset` points (negative = leftward) on a card `width` points wide asks to
 * unload. Only the finger's travel may unload a key, never a fling's velocity.
 */
func unloadRequested(offset: Float, width: Int, loaded: Bool) -> Bool {
    loaded && width > 0 && -offset >= Float(width) * UNLOAD_TRAVEL
}

/** The wallet page's only fixed explanatory line; the rest is state and refusals. */
let BACKUP_WARNING_LINE = "Only on this phone until it is backed up."

struct WalletScreen: View {
    let wallets: WalletsViewModel
    let id: String
    let onBack: () -> Void
    let onKeys: () -> Void
    let onScan: () -> Void
    let onStrips: () -> Void
    let onConnect: () -> Void
    let onBackUp: () -> Void
    let onSign: () -> Void
    let onReview: () -> Void

    @State private var renaming = false
    @State private var draftName = ""
    @State private var removing = false
    @State private var confirmUnload = false

    var body: some View {
        if let wallet = wallets.wallet(id: id) {
            page(wallet)
                .task(id: id) { wallets.leaveSigningUnless(id) }
        } else {
            Color.clear.onAppear { onBack() }
        }
    }

    private func requestUnload() {
        if wallets.needsBackupWarning(id: id) { confirmUnload = true } else { wallets.unload(id: id) }
    }

    @ViewBuilder
    private func page(_ wallet: WalletRecord) -> some View {
        let key = wallets.key(id: id)
        let next = wallets.nextAction(id: id)
        let primary = primaryFor(next: next)
        let go: () -> Void = {
            switch primary {
            case .review: return onReview
            case .backUp: return onBackUp
            case .sign: return onSign
            case .scan: return onScan
            }
        }()
        WalletPage(title: wallet.name, onBack: onBack, titleTag: "wallet-name", actions: {
            Menu {
                Button("Rename wallet") {
                    draftName = wallet.name
                    renaming = true
                }
                .accessibilityIdentifier("rename")
                Button("Remove wallet") { removing = true }
                    .accessibilityIdentifier("forget")
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Wallet options")
            .accessibilityIdentifier("wallet-menu")
        }) {
            KeyCard(fingerprint: wallet.fingerprint, key: key, onUnload: requestUnload)
            if wallets.needsBackupWarning(id: id) {
                Text(BACKUP_WARNING_LINE).font(.bodyMedium).foregroundStyle(Palette.onSurfaceVariant)
            }
            if let notice = wallets.notice, notice.walletId == id {
                Text(notice.text)
                    .foregroundStyle(notice.refusal ? Palette.error : Palette.onSurface)
                    .accessibilityIdentifier("notice")
            }
            if next == .review {
                Color.clear.frame(width: 0, height: 0).accessibilityIdentifier("waiting")
            }
            VStack(spacing: 4) {
                Button(action: go) {
                    Text(primary.label)
                        .id(primary)
                        .transition(.opacity)
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier(primary.tag)
                if primary == .scan {
                    Button("Use share strips", action: onStrips)
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("wallet-scan-strips")
                }
            }
            .animation(Motion.state, value: primary)
            WalletCard(fill: Palette.surface, outlined: true) {
                if primary != .backUp {
                    WalletLink(title: "Back up on paper", tag: "back-up", onClick: onBackUp) {
                        Text(backupLabel(checked: wallet.penlockBackup))
                            .font(.labelMedium)
                            .foregroundStyle(Palette.onSurfaceVariant)
                            .accessibilityIdentifier("backup-status")
                    }
                    .padding(.horizontal, 16)
                }
                WalletLink(title: "Connect to Sparrow", tag: "connect", onClick: onConnect)
                    .padding(.horizontal, 16)
                WalletLink(title: "Key controls", tag: "key-controls", onClick: onKeys)
                    .padding(.horizontal, 16)
            }
            .animation(Motion.state, value: primary)
            if primary == .backUp {
                // The row is gone while the button carries the action; the status still has a home.
                Text(backupLabel(checked: wallet.penlockBackup))
                    .font(.labelMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .accessibilityIdentifier("backup-status")
            }
        }
        .alert("Rename wallet", isPresented: $renaming) {
            TextField("Wallet name", text: $draftName)
                .accessibilityIdentifier("wallet-name-input")
            Button("Save") { _ = wallets.rename(id: id, name: draftName) }
                .disabled(normalizedWalletName(input: draftName) == nil)
                .accessibilityIdentifier("save-name")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("1–40 characters")
        }
        .background {
            Color.clear.alert("Remove \(wallet.name)?", isPresented: $removing) {
                Button("Remove wallet", role: .destructive) {
                    wallets.forget(id: id)
                    removing = false
                    onBack()
                }
                .accessibilityIdentifier("confirm-remove")
                Button("Cancel", role: .cancel) { removing = false }
                    .accessibilityIdentifier("cancel-remove")
            } message: {
                Text(
                    wallets.needsBackupWarning(id: id)
                        ? "This key has no paper backup yet. Removing it here removes it everywhere."
                        : "Removes the saved wallet from this phone. Funds and paper backups are unaffected."
                )
            }
        }
        .overlay {
            Color.clear
                .allowsHitTesting(false)
                .modifier(UnloadWarningDialog(
                    isPresented: $confirmUnload,
                    onKeep: { confirmUnload = false },
                    onUnload: {
                        wallets.unload(id: id)
                        confirmUnload = false
                    }
                ))
        }
    }
}

/**
 * The page's one bold element: what the key is doing, in the worksheet's
 * face. Loaded, the card unloads by a full swipe to the left, or by its
 * accessibility action; released early it settles back and nothing happens.
 */
private struct KeyCard: View {
    let fingerprint: String
    let key: LoadedKey?
    let onUnload: () -> Void

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var armed = false
    @State private var dragging = false

    private var loaded: Bool { key != nil }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard loaded else { return }
                // A mostly vertical drag belongs to the page's scroll.
                if !dragging && abs(value.translation.width) <= abs(value.translation.height) { return }
                dragging = true
                offset = min(0, value.translation.width)
                let past = unloadRequested(offset: Float(offset), width: Int(width), loaded: loaded)
                if past && !armed { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                armed = past
            }
            .onEnded { _ in
                // The release position alone decides; the card always returns to the page.
                let request = dragging && unloadRequested(offset: Float(offset), width: Int(width), loaded: loaded)
                dragging = false
                armed = false
                withAnimation(Motion.state) { offset = 0 }
                if request { onUnload() }
            }
    }

    var body: some View {
        ZStack {
            if offset < 0 {
                HStack {
                    Spacer()
                    Text("Unload").font(.labelLarge)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surfaceContainerHigh)
            }
            content
                .background(RoundedRectangle(cornerRadius: 12).fill(loaded ? Palette.primaryContainer : Palette.surfaceContainer))
                .offset(x: offset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(Motion.state, value: loaded)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(drag, including: loaded ? .all : .subviews)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("key-card")
        .accessibilityActions {
            if loaded { Button("Unload key", action: onUnload) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(loaded ? Palette.primary : Palette.outline)
                    .frame(width: 10, height: 10)
                Text(loaded ? "Key loaded" : "Key not loaded")
                    .font(Typeface.mono(24, relativeTo: .title2))
                    .accessibilityIdentifier("key-status")
            }
            Text(fingerprint)
                .font(Typeface.mono(22, relativeTo: .title3))
                .foregroundStyle(Palette.onSurfaceVariant)
                .accessibilityIdentifier("fingerprint")
            if let key {
                Text(key.source.provenance())
                    .font(.bodyMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
                HStack(spacing: 0) {
                    Image(systemName: "chevron.left")
                    Text("swipe to unload").font(.labelMedium)
                }
                .foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

/** The warning before a key with no paper backup leaves memory. */
struct UnloadWarningDialog: ViewModifier {
    @Binding var isPresented: Bool
    let onKeep: () -> Void
    let onUnload: () -> Void

    func body(content: Content) -> some View {
        content.alert("Unload a key with no paper backup?", isPresented: $isPresented) {
            Button("Unload key", role: .destructive, action: onUnload)
                .accessibilityIdentifier("confirm-unload")
            Button("Keep key loaded", role: .cancel, action: onKeep)
                .accessibilityIdentifier("cancel-unload")
        } message: {
            Text("You will need a backup you can recover from to load it again.")
        }
    }
}
