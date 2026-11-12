import SwiftUI

private struct BackupStage: View {
    let stage: Int

    var body: some View {
        let name = ["Write strips", "Check backup", "Store separately"][stage - 1]
        VStack(alignment: .leading, spacing: 8) {
            Text("Step \(stage) of 3 · \(name)")
                .font(.bodyMedium)
                .accessibilityIdentifier("backup-stage")
            ProgressView(value: Double(stage) / 3)
                .tint(Palette.primary)
                .accessibilityIdentifier("backup-progress")
                .accessibilityValue("Step \(stage) of 3 · \(name)")
        }
    }
}

/** An invalidated attempt waits for an explicit exit, including during a pop animation. */
struct EndedBackupScreen: View {
    let onDone: () -> Void

    var body: some View {
        TaskPage(
            title: "Penlock backup",
            onBack: onDone,
            actions: {
                Button("Return", action: onDone)
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("return-ended-backup")
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This backup attempt has ended")
                        .font(.headlineMedium)
                        .accessibilityIdentifier("backup-ended")
                    Text("Its on-screen strips are no longer available. Return to your wallets to start again.")
                        .font(.bodyLarge)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/** Shares are made once on entry, never by changing pages or retrying a check. */
struct SharesScreen: View {
    let wallets: WalletsViewModel
    let onCheck: () -> Void
    let onDone: () -> Void

    @State private var page = 0
    @State private var confirmExit = false

    var body: some View {
        if let backup = wallets.backup {
            shares(backup.shares)
        } else {
            EndedBackupScreen(onDone: onDone)
        }
    }

    private func shares(_ shares: [ShareText]) -> some View {
        let exit = { confirmExit = true }
        let current = min(page, max(shares.count - 1, 0))
        return TaskPage(
            title: "Penlock backup",
            onBack: exit,
            actions: {
                if current < shares.count - 1 {
                    Button("Next strip") { withAnimation(Motion.state) { page = current + 1 } }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("next-share")
                } else {
                    Button("Check the strips", action: onCheck)
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("check-strips")
                    Button("Finish without checking", action: exit)
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("done-shares")
                }
                Button("Previous strip") { withAnimation(Motion.state) { page = current - 1 } }
                    .buttonStyle(.secondary)
                    .disabled(current <= 0)
                    .accessibilityIdentifier("prev-share")
            }
        ) {
            TabView(selection: $page) {
                ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                    SharePage(share: share, page: index, count: shares.count)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .alert("Leave this backup attempt?", isPresented: $confirmExit) {
            Button("Exit backup", action: onDone)
                .accessibilityIdentifier("confirm-exit-backup")
            Button("Keep writing", role: .cancel) { confirmExit = false }
                .accessibilityIdentifier("keep-writing")
        } message: {
            Text(
                "No new successful check will be recorded by leaving. Any earlier check date stays " +
                    "unchanged. The strips on this screen will be discarded; starting again makes " +
                    "a new set. Don’t mix strips from different attempts. Your key stays loaded."
            )
        }
    }
}

private struct SharePage: View {
    let share: ShareText
    let page: Int
    let count: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BackupStage(stage: 1)
                Text("Strip \(share.number) of \(count)")
                    .font(.headlineMedium)
                    .accessibilityIdentifier("share-title")
                Text("Copy each row onto the paper labelled Share \(share.number), in order.")
                    .font(.bodyLarge)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(share.rows.enumerated()), id: \.offset) { i, row in
                            HStack(alignment: .center, spacing: 0) {
                                Text("\(i + 1).")
                                    .font(Typeface.mono(16, relativeTo: .headline))
                                    .foregroundStyle(Palette.onSurfaceVariant)
                                    .frame(minWidth: 40, alignment: .leading)
                                Text(row)
                                    .font(Typeface.mono(28, relativeTo: .title))
                                    .tracking(4)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .accessibilityIdentifier("share-row-\(i + 1)")
                                    .accessibilityLabel("Row \(i + 1): \(row.map(String.init).joined(separator: " "))")
                            }
                        }
                    }
                    .padding(16)
                }
                .accessibilityIdentifier("strip-symbols")
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.outlineVariant))
                Text(
                    page == count - 1
                        ? "Written all three? Photograph two strips to check that they recover this wallet."
                        : "Keep these strips private. Any two can recover the wallet."
                )
                .font(.bodyLarge)
                .foregroundStyle(Palette.onSurfaceVariant)
                Text("This attempt is checked only after a matching pair is read back.")
                    .font(.bodyLarge)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("strip-page-\(page + 1)")
    }
}

struct BackupCheckScreen: View {
    let onScan: () -> Void
    let onBack: () -> Void

    var body: some View {
        TaskPage(
            title: "Check backup",
            onBack: onBack,
            actions: {
                Button("Scan two strips", action: onScan)
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("scan-backup")
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BackupStage(stage: 2)
                    Text("Check what you wrote").font(.headlineMedium)
                    Text("Choose two different strips from this set. Photograph one, then the other.")
                        .font(.bodyLarge)
                    Text(
                        "The recovered words are compared with this wallet’s loaded key. " +
                            "Only a matching pair records a successful check."
                    )
                    .font(.bodyLarge)
                    Text("The third strip is not verified by this check. Keep all three private.")
                        .font(.bodyLarge)
                        .foregroundStyle(Palette.onSurfaceVariant)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/** Only this attempt's check, never a saved date, selects the success state. */
struct CheckedScreen: View {
    let wallets: WalletsViewModel
    let onAgain: () -> Void
    let onRetry: () -> Void
    let onDone: () -> Void

    var body: some View {
        let backup = wallets.backup
        if let backup, let key = wallets.key(id: backup.walletId), let check = backup.check {
            checked(key: key, check: check)
        } else {
            EndedBackupScreen(onDone: onDone)
        }
    }

    private func checked(key: LoadedKey, check: StripCheck) -> some View {
        let mismatch = check.mismatch
        let success = mismatch == nil
        let back = success ? onDone : onAgain
        return TaskPage(
            title: success ? "Backup checked" : "Check needs attention",
            onBack: back,
            actions: {
                if success {
                    Button("Return to wallet", action: onDone)
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("done-check")
                } else {
                    Button("Scan the pair again", action: onRetry)
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("retry-check")
                    Button("Review the written strips", action: onAgain)
                        .buttonStyle(.outlined)
                        .accessibilityIdentifier("back-to-shares")
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BackupStage(stage: success ? 3 : 2)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(success ? "Two strips recover this wallet" : "The strips differ")
                            .font(.headlineSmall)
                        Text(resultText(key: key, check: check))
                            .font(.bodyLarge)
                            .accessibilityIdentifier("check-result")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceContainerHighest))
                    Text(success ? "Store all three strips separately" : "This attempt has not passed")
                        .font(.titleLarge)
                    Text(
                        success
                            ? "Keep each strip in a different safe place. Any two can recover the wallet."
                            : "No successful check was recorded for this attempt. Any earlier check date is unchanged."
                    )
                    .font(.bodyLarge)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func resultText(key: LoadedKey, check: StripCheck) -> String {
        guard let row = check.mismatch else {
            return "The pair you scanned matches the loaded key, word for word. " +
                "The third strip has not been checked."
        }
        let read = check.read.indices.contains(row) ? check.read[row] : "nothing"
        let expected = key.words.indices.contains(row) ? key.words[row] : "nothing"
        return "Row \(row + 1) differs: the strips give \"\(read)\", the key has \"\(expected)\". " +
            "Compare that row on both strips with the on-screen symbols, rewrite, then scan again."
    }
}
