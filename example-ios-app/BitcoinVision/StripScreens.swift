import SwiftUI

/** The camera and its result are separate in-page states; no sheet is needed. */
struct StripScanScreen: View {
    let viewModel: StripsViewModel
    let onRecovered: () -> Void
    let onExit: () -> Void

    var body: some View {
        // a photograph being read, or read and failed, is shown as the
        // photograph; a strip read, or a combination that failed, is the
        // result card
        switch viewModel.attempts.current {
        case .preparing:
            CapturedPhotoScreen(
                title: "Preparing your photo", photo: nil, error: nil, onRetake: { viewModel.retake() },
                onProgressPresented: { viewModel.progressPresented(token: $0, sequence: $1) },
                stripProgress: viewModel.progress
            )
        case let .processing(_, photo):
            CapturedPhotoScreen(
                title: "Reading the strip", photo: photo, error: nil, onRetake: { viewModel.retake() },
                onProgressPresented: { viewModel.progressPresented(token: $0, sequence: $1) },
                stripProgress: viewModel.progress
            )
        case let .failed(_, photo, message, _):
            CapturedPhotoScreen(title: "No strip read", photo: photo, error: message, onRetake: { viewModel.retake() }) {
                SavePhotoForDiagnosis { await viewModel.savePhoto() }
                if photo != nil {
                    SavePhotoForDiagnosis(canonical: true) { await viewModel.saveCanonicalPhoto() }
                }
            }
        default:
            scanOrResult
        }
    }

    @ViewBuilder private var scanOrResult: some View {
        let capture = viewModel.capture
        switch capture {
        case .some(.found), .some(.failed):
            CaptureResult(viewModel: viewModel, capture: capture!, onRecovered: onRecovered)
        default:
            camera(shutterEnabled: capture == nil)
        }
    }

    private func camera(shutterEnabled: Bool) -> some View {
        var heldNumber: UInt8?
        if case let .scanning(held) = viewModel.scan, let held { heldNumber = viewModel.shareNumber(strip: held) }
        return CameraCapture(
            shutterEnabled: shutterEnabled,
            onShutter: { viewModel.begin() },
            onJpeg: { token, photo in viewModel.deliverPhoto(token: token, photo: photo) },
            onExit: onExit,
            bar: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(heldNumber == nil ? "1 of 2 · Scan first strip" : "2 of 2 · Scan second strip")
                        .font(.titleMedium)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("strip-scan-stage")
                    if let heldNumber {
                        Text("Share \(heldNumber) read")
                            .font(.bodyMedium)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }
}

private func readingSummary(_ strip: StripReading) -> String {
    let review = strip.review()
    let unread = review.rows.reduce(0) { sum, row in
        sum + row.cells.filter { $0.unread && $0.replacement == nil }.count
    }
    let uncertain = review.rows.reduce(0) { sum, row in
        sum + row.cells.filter { !$0.unread && $0.replacement == nil && ($0.probability ?? 0) < 0.75 }.count
    }
    return "\(strip.rows()) rows read" +
        (unread > 0 ? ", \(unread) cells unread" : "") +
        (uncertain > 0 ? ", \(uncertain) low confidence" : "")
}

private func percent(_ probability: Float?) -> String? {
    probability.map { "\(Int($0 * 100))%" }
}

private let worksheetSymbols = Array("=#ABCDEFGHIJKLMNOPQRSTUVWXYZ-")

/** Kotlin's tertiary colour role, which is the palette's graphite. */
private let tertiary = Palette.secondary

private struct CellEdit: Identifiable {
    let row: Int
    let cell: StripCellReview
    var id: String { "\(row)-\(cell.position)" }
}

private struct CaptureResult: View {
    let viewModel: StripsViewModel
    let capture: Capture
    let onRecovered: () -> Void

    @State private var cellEdit: CellEdit?
    @State private var rowEdit: Int?
    @State private var rowText = ""
    @State private var acknowledged = false
    // A newly edited strip must never inherit the previous strip's completed
    // pair check while the new check is still running.
    @State private var pairState: (strip: StripReading, pair: CombinedStripReview?)?

    private var found: [StripReading]? {
        if case let .found(strips) = capture { return strips }
        return nil
    }
    private var raw: StripReading? { found.flatMap { viewModel.usable(strips: $0) } }
    private var next: StripReading? { raw.map { viewModel.currentStrip(strip: $0) } }
    private var held: StripReading? {
        if case let .scanning(held) = viewModel.scan { return held }
        return nil
    }

    var body: some View {
        let raw = self.raw
        let next = self.next
        let held = self.held
        let currentPairState = pairState.flatMap { $0.strip === next ? $0 : nil }
        let pair = currentPairState?.pair
        let flagged = pair?.rows.contains { $0.status != .exact } == true
        let retake = { viewModel.retake() }
        TaskPage(
            title: next != nil ? "Review strip" : "Strip needs attention",
            onBack: retake,
            actions: {
                if let next {
                    Button("Use share \(viewModel.shareNumber(strip: next).map(String.init) ?? "null")") {
                        if viewModel.use(strip: next, paperChecked: acknowledged) { onRecovered() }
                    }
                    .buttonStyle(.primary)
                    .disabled(!shareUseAllowed(firstShareHeld: held != nil, pair: pair, paperChecked: acknowledged))
                    .accessibilityIdentifier("use")
                    Button("Retake", action: retake)
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("retake")
                } else {
                    Button("Retake", action: retake)
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("retake")
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let next, let photo = viewModel.attempts.resolvedPhoto {
                        StripPhoto(photo: photo, review: next.review())
                    }
                    summaryCard(next: next)
                    if let next {
                        Text("Check the share number and all twelve rows against your paper. A single share has no standalone checksum.")
                            .font(.bodyLarge)
                        ForEach(Array(next.review().rows.enumerated()), id: \.offset) { rowIndex, row in
                            rowCard(rowIndex: rowIndex, row: row)
                        }
                        if let held {
                            Text("Combined check").font(.titleMedium)
                            if let firstPhoto = viewModel.heldPhoto {
                                Text("First share on its photo").font(.bodyMedium)
                                StripPhoto(photo: firstPhoto, review: held.review())
                            }
                            if currentPairState == nil {
                                Text("Checking combined rows…").font(.bodyLarge)
                            } else if pair == nil {
                                Text("The shares cannot be combined. Review unclear cells or retake.").font(.bodyLarge)
                            }
                            ForEach(Array((pair?.rows ?? []).enumerated()), id: \.offset) { _, row in
                                Text("Row \(row.number) · " + combinedStatus(row))
                                    .font(.bodyLarge)
                                    .foregroundStyle(row.status == .needsReview ? Palette.error : Palette.onSurface)
                            }
                            if flagged {
                                Button { acknowledged.toggle() } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: acknowledged ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(acknowledged ? Palette.primary : Palette.onSurfaceVariant)
                                            .font(.system(size: 22))
                                        Text("I checked every corrected or uncertain row against both paper strips.")
                                            .font(.bodyLarge)
                                            .foregroundStyle(Palette.onSurface)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(acknowledged ? .isSelected : [])
                            }
                        }
                        if let error = viewModel.editError {
                            Text(error).font(.bodyLarge).foregroundStyle(Palette.error)
                        }
                    }
                    SavePhotoForDiagnosis { await viewModel.savePhoto() }
                    if viewModel.attempts.resolvedPhoto != nil {
                        SavePhotoForDiagnosis(canonical: true) { await viewModel.saveCanonicalPhoto() }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: raw.map(ObjectIdentifier.init), initial: false) {
            cellEdit = nil
            rowEdit = nil
        }
        .onChange(of: next.map(ObjectIdentifier.init), initial: false) { acknowledged = false }
        .task(id: PairKey(held: held, next: next)) {
            pairState = nil
            guard let held, let next else { return }
            let review = await Task.detached { try? reviewCombinedStrips(a: held, b: next) }.value
            if Task.isCancelled { return }
            pairState = (next, review)
        }
        .sheet(item: $cellEdit) { edit in
            cellSheet(edit, raw: raw)
        }
        .alert(
            "Edit row \((rowEdit ?? 0) + 1)",
            isPresented: Binding(get: { rowEdit != nil }, set: { if !$0 { rowEdit = nil } })
        ) {
            TextField("Six worksheet symbols", text: $rowText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: rowText) { _, value in
                    let clamped = String(value.uppercased().prefix(6))
                    if clamped != value { rowText = clamped }
                }
            Button("Apply") {
                if let raw, let row = rowEdit {
                    viewModel.correctRow(strip: raw, row: row, text: String(rowText.uppercased().prefix(6)))
                }
                rowEdit = nil
            }
            Button("Cancel", role: .cancel) { rowEdit = nil }
        }
    }

    private struct PairKey: Equatable {
        let held: ObjectIdentifier?
        let next: ObjectIdentifier?
        init(held: StripReading?, next: StripReading?) {
            self.held = held.map(ObjectIdentifier.init)
            self.next = next.map(ObjectIdentifier.init)
        }
    }

    private func summaryCard(next: StripReading?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                next != nil ? "Share \(viewModel.shareNumber(strip: next!).map(String.init) ?? "null")"
                    : found != nil ? "Not this strip" : "No strip read"
            )
            .font(.headlineSmall)
            Text(summaryText(next: next))
                .font(.bodyLarge)
                .accessibilityIdentifier("strip-read-result")
                .accessibilityValue(next != nil ? "Ready to use" : "Retake needed")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceContainerHighest))
    }

    private func summaryText(next: StripReading?) -> String {
        if let next { return readingSummary(next) }
        if let found { return viewModel.refusal(strips: found) }
        if case let .failed(message) = capture { return message }
        return ""
    }

    private func rowCard(rowIndex: Int, row: StripRowReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Row \(row.number)").font(.titleMedium)
            HStack(spacing: 3) {
                ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                    Button { cellEdit = CellEdit(row: rowIndex, cell: cell) } label: {
                        Text(cell.replacement ?? cell.selected ?? "?")
                            .font(.labelLarge)
                            .foregroundStyle(cellColour(cell))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(cell.position < 2 ? Palette.secondaryContainer : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("strip-cell-\(rowIndex + 1)-\(cell.position + 1)")
                }
            }
            Text("First two: shares of checksum symbols · last four: word symbols").font(.bodySmall)
            Text(row.cells.map { cell in
                "\(cell.position + 1): \(percent(cell.probability) ?? "unread")" +
                    (cell.replacement.map { " → \($0)" } ?? "")
            }.joined(separator: " · "))
            .font(.bodySmall)
            Button("Edit full row") {
                rowText = row.cells.map { $0.replacement ?? $0.selected ?? "?" }.joined()
                rowEdit = rowIndex
            }
            .font(.labelLarge)
            .foregroundStyle(Palette.primary)
            .accessibilityIdentifier("edit-strip-row-\(rowIndex + 1)")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceContainerHighest))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("strip-row-\(rowIndex + 1)")
    }

    private func cellColour(_ cell: StripCellReview) -> Color {
        if cell.unread && cell.replacement == nil { return Palette.error }
        if cell.replacement != nil { return tertiary }
        if (cell.probability ?? 0) < 0.75 { return Palette.error }
        return Palette.onSurface
    }

    private func combinedStatus(_ row: CombinedRowReview) -> String {
        switch row.status {
        case .exact:
            return "word code matches combined reading"
        case .corrected:
            return "word code corrects symbol \((row.position ?? 0) + 1): \(row.observed ?? "null") → \(row.expected ?? "null")"
        case .needsReview:
            return "ambiguous or weak reading; check both strips"
        }
    }

    private func cellSheet(_ edit: CellEdit, raw: StripReading?) -> some View {
        let cell = edit.cell
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Model: \(cell.selected ?? "unread") · \(percent(cell.probability) ?? "no confidence")")
                        .font(.bodyLarge)
                    ForEach(0..<((worksheetSymbols.count + 5) / 6), id: \.self) { line in
                        HStack(spacing: 0) {
                            ForEach(worksheetSymbols[(line * 6)..<min(line * 6 + 6, worksheetSymbols.count)], id: \.self) { symbol in
                                Button(String(symbol)) {
                                    if let raw {
                                        viewModel.correctCell(strip: raw, row: edit.row, position: Int(cell.position),
                                                              text: String(symbol))
                                    }
                                    cellEdit = nil
                                }
                                .font(Typeface.mono(18))
                                .foregroundStyle(Palette.primary)
                                .frame(width: 48, height: 44)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Row \(edit.row + 1), cell \(cell.position + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { cellEdit = nil }
                }
                if cell.replacement != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Use model read") {
                            if let raw { viewModel.resetCell(strip: raw, row: edit.row, position: Int(cell.position)) }
                            cellEdit = nil
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
