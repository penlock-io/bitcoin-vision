import SwiftUI

// The Android screen sets FLAG_SECURE here; the app's privacy cover already does that job globally.
struct NewSeedScreen: View {
    let model: NewSeedViewModel
    let onCancel: () -> Void
    let onComplete: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            // The camera may abandon a shutter callback when the app leaves the screen.
            // Revoke that capture so returning offers a usable shutter, not a stale photo.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && model.capturing { model.retake() }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .idle:
            WalletPage(title: "Setup ended", onBack: onCancel) {
                Text("No new wallet was saved. If iOS closed the app, start again with a new phrase.")
                    .font(.bodyLarge)
                Button("Back to wallets", action: onCancel)
                    .buttonStyle(.primary)
            }
        case .writing:
            WalletPage(title: "Write down your phrase", onBack: onCancel, titleTag: "write-key") {
                Text("Write all 12 words in order on paper, then photograph the whole list. " +
                    "Review the photo's reading before saving the wallet, and check any misread words against your paper.")
                    .font(.bodyLarge)
                Text("Keep this screen private. The pending key and photo stay in memory only. " +
                    "Cancelling or the app being closed by iOS abandons setup. Do not use this wallet yet.")
                    .font(.bodyLarge)
                PhraseBody(words: model.words)
                Button("Photograph my written backup") { model.retake() }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("photograph-backup")
            }
        case .camera:
            CameraCapture(
                shutterEnabled: !model.capturing,
                onShutter: { model.begin() },
                onJpeg: { token, photo in model.deliver(token: token, photo: photo) },
                onExit: { model.showWords() },
                bar: { Text("Photograph all 12 written words").foregroundStyle(.white) }
            )
        case .reading:
            CapturedPhotoScreen(
                title: "Checking your written backup", photo: model.photo, error: nil,
                onRetake: { model.retake() }, progress: model.progress,
                onProgressPresented: { model.progressPresented(token: $0, sequence: $1) }
            )
        case .review, .verified:
            BackupWordReview(model: model, onCancel: onCancel, onComplete: onComplete)
        }
    }
}

/** Same word rows and confidence display as recovery, with a known-word comparison.
 * Tap reviews a discrepancy, rather than editing the immutable generated seed. */
private struct BackupWordReview: View {
    let model: NewSeedViewModel
    let onCancel: () -> Void
    let onComplete: () -> Void

    @State private var inspecting: Inspected?

    private struct Inspected: Identifiable {
        let position: Int
        var id: Int { position }
    }

    var body: some View {
        let ready = model.stage == .verified
        TaskPage(
            title: "Review the words",
            onBack: onCancel,
            actions: {
                Text(model.message ?? "Retake your written backup.")
                    .font(.bodyMedium)
                    .foregroundStyle(ready ? Palette.onSurface : Palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("backup-status")
                Button("Continue to wallet", action: onComplete)
                    .buttonStyle(.primary)
                    .disabled(!ready)
                    .accessibilityIdentifier("complete-new-wallet")
            }
        ) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let photo = model.photo, let frame = model.frame {
                            PhotoWithBoxes(photo: photo, width: frame.width, height: frame.height,
                                           entries: model.entries, leftOut: [], highlighted: nil,
                                           unreadSources: [], highlightedSource: nil)
                        }
                        Text("Compare the photo with your generated phrase. Tap a word to inspect it. " +
                            "If a word is wrong, make its handwriting clearer on paper and retake, " +
                            "or acknowledge the misread after checking the paper.")
                            .font(.bodyLarge)
                        Text("Reading order (choose the layout on your paper)")
                            .font(.bodyLarge)
                        HStack(spacing: 8) {
                            ForEach([Order.numbers, .columns, .rows].filter { model.availableOrders.contains($0) },
                                    id: \.self) { order in
                                orderChip(order)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { i, entry in
                        WordRow(number: i + 1, entry: entry, showCrop: false, onClick: { inspecting = Inspected(position: i) },
                                expectedWord: model.words.indices.contains(i) ? model.words[i] : "No word expected",
                                acknowledged: model.acknowledged.contains(i))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Retake photo") { model.retake() }
                            .buttonStyle(.primary)
                            .accessibilityIdentifier("backup-retake")
                        Button("Show the same generated phrase") { model.showWords() }
                            .buttonStyle(.secondary)
                    }
                    .padding(24)
                }
            }
            .accessibilityIdentifier("review-list")
        }
        .onChange(of: model.order) { inspecting = nil }
        .onChange(of: model.stage) { inspecting = nil }
        .sheet(item: $inspecting) { inspected in
            inspector(position: inspected.position)
        }
    }

    private func orderChip(_ order: Order) -> some View {
        let selected = model.order == order
        let name: String
        switch order {
        case .numbers: name = "By detected numbers"
        case .columns: name = "Down columns"
        case .rows: name = "Across rows"
        }
        let tag: String
        switch order {
        case .numbers: tag = "order-numbers"
        case .columns: tag = "order-columns"
        case .rows: tag = "order-rows"
        }
        return Button { model.chooseOrder(order: order) } label: {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
                Text(name).font(.labelLarge)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(selected ? Palette.onSecondaryContainer : Palette.onSurfaceVariant)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Palette.secondaryContainer : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.clear : Palette.outline))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(tag)
    }

    @ViewBuilder private func inspector(position: Int) -> some View {
        let entries = model.entries
        if entries.indices.contains(position) {
            let entry = entries[position]
            let expected: String? = model.words.indices.contains(position) ? model.words[position] : nil
            let wrong = entry.word != expected
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let source = entry.source {
                            Crop(png: source.cropPng)
                                .frame(maxWidth: .infinity)
                                .frame(height: 72)
                        }
                        Text("Expected: \(expected ?? "No word expected")").font(.bodyLarge)
                        Text("Photo read: \(entry.word)").font(.bodyLarge)
                        if wrong {
                            Text("Check that your paper says the expected word. Try making the handwriting " +
                                "clearer and retaking the photo. Acknowledging this misread does not change your seed.")
                                .font(.bodyLarge)
                        }
                        if wrong && !model.acknowledged.contains(position) && model.readWords.count == 12 {
                            Button("I checked the paper · acknowledge misread") {
                                model.acknowledge(position: position)
                                inspecting = nil
                            }
                            .buttonStyle(.primary)
                            .accessibilityIdentifier("acknowledge-word")
                        }
                        Button("Retake photo") {
                            inspecting = nil
                            model.retake()
                        }
                        .buttonStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Word \(position + 1)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { inspecting = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
