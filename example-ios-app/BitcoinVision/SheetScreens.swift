import PhotosUI
import SwiftUI
import UIKit

// The verdict colours: the same on both themes, since they carry
// meaning the theme must not restyle.
private let Accepted = Color(red: 0x2E / 255, green: 0x7D / 255, blue: 0x32 / 255)
private let Uncertain = Color(red: 0xF9 / 255, green: 0xA8 / 255, blue: 0x25 / 255)
private let LeftOut = Color(red: 0x9E / 255, green: 0x9E / 255, blue: 0x9E / 255)
private let LowConfidence = Color(red: 0xB3 / 255, green: 0x26 / 255, blue: 0x1E / 255)

/** One palette for row confidence and the corresponding polygon on the photo. */
func confidenceColour(entry: Entry) -> Color {
    guard let confidence = entry.modelConfidence else { return LeftOut }
    if let source = entry.source, source.accepted && source.read == entry.word { return Accepted }
    return confidence >= 0.5 ? Uncertain : LowConfidence
}

private let rootLocale = Locale(identifier: "en_US_POSIX")

/** A text button on the camera's dark bar. */
private struct BarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.labelLarge).foregroundStyle(.white).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

struct SheetScanScreen: View {
    let viewModel: SheetViewModel
    let onReviewed: () -> Void
    let onExit: () -> Void

    @State private var choosing = false
    @State private var picked: PhotosPickerItem?

    init(viewModel: SheetViewModel, onReviewed: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onReviewed = onReviewed
        self.onExit = onExit
    }

    var body: some View {
        content
            // The read ends in the view model; this screen takes the one
            // navigation it asks for and clears the request.
            .onChange(of: viewModel.reviewed, initial: true) { _, reviewed in
                if reviewed {
                    viewModel.reviewed = false
                    ScanTrace.mark("review_navigation")
                    onReviewed()
                }
            }
            // The scanner reads JPEG, PNG or WebP: the library hands over a compatible encoding.
            .photosPicker(isPresented: $choosing, selection: $picked, matching: .images,
                          preferredItemEncoding: .compatible)
            .onChange(of: picked) { _, item in
                // A cancelled picker is not a failed scan: nothing was chosen.
                guard let item else { return }
                picked = nil
                viewModel.deliverDocument(item: item)
            }
    }

    private func current(_ token: Int) -> ScanProgressState? {
        viewModel.progress.flatMap { $0.token == token ? $0 : nil }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.attempts.current {
        case let .preparing(token, _):
            CapturedPhotoScreen(
                title: "Preparing your photo", photo: nil, error: nil,
                onRetake: { viewModel.retake() },
                progress: current(token),
                onProgressPresented: { viewModel.progressPresented(token: $0, sequence: $1) }
            )
        case let .processing(token, photo):
            CapturedPhotoScreen(
                title: "Reading your photo", photo: photo, error: nil,
                onRetake: { viewModel.retake() },
                progress: current(token),
                onProgressPresented: { viewModel.progressPresented(token: $0, sequence: $1) }
            )
        case let .failed(_, photo, message, _):
            CapturedPhotoScreen(title: "No words read", photo: photo, error: message, onRetake: { viewModel.retake() }) {
                SavePhotoForDiagnosis { await viewModel.savePhoto() }
                if photo != nil {
                    SavePhotoForDiagnosis(canonical: true) { await viewModel.saveCanonicalPhoto() }
                }
            }
        case let attempt:
            CameraCapture(
                shutterEnabled: attempt == nil,
                onShutter: { viewModel.begin() },
                onJpeg: { token, photo in viewModel.deliverPhoto(token: token, photo: photo) },
                onExit: onExit,
                bar: {
                    Text("1 of 2 · Take the photo")
                        .font(.titleMedium)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BarButton(title: "Choose photo") { choosing = true }
                        .accessibilityIdentifier("choose-file")
                    #if DEBUG
                    BarButton(title: viewModel.traceNextScan ? "Trace next: on" : "Trace next: off") {
                        viewModel.toggleDecisionTrace()
                    }
                    .accessibilityIdentifier("trace-next-scan")
                    #endif
                    // The Android debug build's "From file" fixture route reads a
                    // directory only adb can fill; it has no iOS counterpart.
                },
                overlay: { Guidance() },
                instead: {
                    // Refusing the camera leaves a photo already on the phone
                    // as the only way in, so it cannot live behind the preview.
                    Button("Choose a photo") { choosing = true }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("choose-file")
                }
            )
        }
    }
}

private struct Guidance: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Lay the sheet flat, every word in the frame, in good light. " +
                 "A printed recovery phrase sheet is read field by field; any other page word by word.")
                .font(.bodyMedium)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Palette.cameraScrim)
                .padding(.horizontal, 24)
                .padding(.bottom, 128)
        }
    }
}

/**
 * A bad read is diagnosed on the desk, from the photo the phone took:
 * a debug build can write it where Xcode downloads the app's container
 * from. A release build never writes a phrase's photo anywhere, so it
 * gets no button.
 */
struct SavePhotoForDiagnosis: View {
    let canonical: Bool
    let save: () async -> String?
    @State private var saved: String?
    @State private var saving = false

    init(canonical: Bool = false, save: @escaping () async -> String?) {
        self.canonical = canonical
        self.save = save
    }

    var body: some View {
        #if DEBUG
        VStack(alignment: .leading, spacing: 4) {
            Button(canonical ? "Save upright photo for diagnosis" : "Save raw photo + metadata for diagnosis") {
                saving = true
                Task { @MainActor in
                    saved = await save() ?? "Could not save photo"
                    saving = false
                }
            }
            .buttonStyle(.secondary)
            .disabled(saving)
            .accessibilityIdentifier(canonical ? "save-canonical-photo" : "save-photo")
            if let saved {
                Text(saved).font(.bodySmall).accessibilityIdentifier("saved-photo")
            }
        }
        #else
        EmptyView()
        #endif
    }
}

/** What the edit sheet is open for. */
private enum Editing: Identifiable {
    case word(id: Int)

    /** A word typed in at entry `at`; with `number`, filling that gap in the page's run. */
    case insert(at: Int, number: Int? = nil)

    var id: String {
        switch self {
        case let .word(id): return "word-\(id)"
        case let .insert(at, number): return "insert-\(at)-\(number.map(String.init) ?? "")"
        }
    }
}

/** State removal never navigates a composing or outgoing page by itself. */
private struct EndedWordReview: View {
    let onBack: () -> Void

    var body: some View {
        TaskPage(title: "Word review", onBack: onBack) {
            Button("Return", action: onBack)
                .buttonStyle(.primary)
                .accessibilityIdentifier("return-ended-review")
        } content: {
            Text("This scan is no longer available.")
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("review-ended")
        }
    }
}

struct ReviewScreen: View {
    let viewModel: SheetViewModel
    let action: String
    let onAccept: () -> Void
    let onBack: () -> Void

    @State private var editing: Editing?
    @State private var showLeftOut = false
    @State private var highlightedSource: UInt32?
    @State private var toTop = 0
    @State private var locating = false

    init(viewModel: SheetViewModel, action: String, onAccept: @escaping () -> Void, onBack: @escaping () -> Void) {
        self.viewModel = viewModel
        self.action = action
        self.onAccept = onAccept
        self.onBack = onBack
    }

    var body: some View {
        if let draft = viewModel.draft, let scan = viewModel.scan, let photo = viewModel.photo {
            review(draft: draft, scan: scan, photo: photo)
        } else {
            EndedWordReview(onBack: onBack)
        }
    }

    private func review(draft: PhraseDraft, scan: PhraseScan, photo: ResolvedPhoto) -> some View {
        let passes = viewModel.passes()
        let unreadSources = scan.sources.filter(\.unread)
        let reviewLeftOut = draft.reviewLeftOut
        let missingAt = draft.missingAt()
        return TaskPage(
            title: "Review the words",
            onBack: onBack,
            bar: {
                Button { toTop += 1 } label: { Image(systemName: "photo") }
                    .accessibilityLabel("Go to the source photo")
                    .accessibilityValue("Expanded")
                    .accessibilityIdentifier("toggle-photo")
            },
            actions: {
                Text(viewModel.status())
                    .font(.bodyMedium)
                    .foregroundStyle(passes ? Palette.onSurface : Palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("status")
                    .accessibilityAddTraits(.updatesFrequently)
                Button(action, action: onAccept)
                    .buttonStyle(.primary)
                    .disabled(!passes)
                    .accessibilityIdentifier("accept")
            },
            content: {
                ScrollViewReader { list in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            header(draft: draft, scan: scan, photo: photo, unreadSources: unreadSources,
                                   reviewLeftOut: reviewLeftOut)
                                .id("top")
                            ForEach(Array(draft.entries.enumerated()), id: \.element.id) { i, entry in
                                InsertRow(at: i, missing: missingAt[i]) {
                                    editing = .insert(at: i, number: missingAt[i])
                                }
                                WordRow(
                                    number: i + 1,
                                    entry: entry,
                                    showCrop: false,
                                    onClick: {
                                        highlightedSource = nil
                                        viewModel.highlighted = entry.source == nil ? nil : entry.id
                                        editing = .word(id: entry.id)
                                    },
                                    // by number, a row is named by the number written beside it
                                    label: draft.order == .numbers ? (entry.number.map { "\($0)." } ?? "–") : "\(i + 1)."
                                )
                            }
                            InsertRow(at: draft.entries.count, missing: missingAt[draft.entries.count]) {
                                editing = .insert(at: draft.entries.count, number: missingAt[draft.entries.count])
                            }
                            if !reviewLeftOut.isEmpty || !unreadSources.isEmpty {
                                leftOutSection(draft: draft, reviewLeftOut: reviewLeftOut,
                                               unreadSources: unreadSources, list: list)
                            }
                            // the desk's tool, at the end and on debug builds only
                            VStack(alignment: .leading) {
                                SavePhotoForDiagnosis { await viewModel.savePhoto() }
                                SavePhotoForDiagnosis(canonical: true) { await viewModel.saveCanonicalPhoto() }
                            }
                            .padding(.horizontal, 24)
                            Spacer().frame(height: 24)
                        }
                    }
                    .accessibilityIdentifier("review-list")
                    .traceReviewFrame()
                    .onChange(of: toTop) { _, _ in withAnimation(Motion.state) { list.scrollTo("top", anchor: .top) } }
                }
            }
        )
        .sheet(item: $editing, onDismiss: {
            if !locating { viewModel.highlighted = nil }
            locating = false
        }) { what in
            EditSheet(
                viewModel: viewModel,
                what: what,
                onDismiss: {
                    editing = nil
                    viewModel.highlighted = nil
                },
                onLocate: {
                    locating = true
                    editing = nil
                    toTop += 1
                }
            )
        }
    }

    @ViewBuilder
    private func header(draft: PhraseDraft, scan: PhraseScan, photo: ResolvedPhoto, unreadSources: [DetectionSource],
                        reviewLeftOut: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer().frame(height: 8)
            Text(scan.layout == .wordSheet ? "Read from a recovery phrase card" : "Read as a page of words")
                .font(.titleSmall)
                .accessibilityIdentifier("scan-source")
            PhotoWithBoxes(
                photo: photo, width: Int(scan.width), height: Int(scan.height),
                entries: draft.entries, leftOut: reviewLeftOut, highlighted: viewModel.highlighted,
                unreadSources: unreadSources, highlightedSource: highlightedSource
            )
            let selected = draft.entries.firstIndex { $0.id == viewModel.highlighted }
            if let source = unreadSources.first(where: { $0.detectorId == highlightedSource }) {
                Text(source.reviewDescription).accessibilityIdentifier("photo-source-selection")
                Text("No separate word was read here. If a word is missing, use + at its place in the list to type it.")
                    .font(.bodyMedium)
            } else if let selected {
                Text("Highlighted: word \(selected + 1)").accessibilityIdentifier("photo-selection")
            }
            // a word sheet's fields have one order; a page has two,
            // and a third when its numbers were read as a run
            if scan.layout == .page {
                Spacer().frame(height: 4)
                let orders = Order.entries.filter { $0 != .numbers || draft.numbered }
                Picker("Reading order", selection: Binding(
                    get: { draft.order },
                    set: { viewModel.reorder(order: $0) }
                )) {
                    ForEach(orders, id: \.self) { order in
                        Text(orderLabel(order)).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("order")
                if let note = numberingNote(numbers: draft.numbers, listNumbered: draft.listNumbered) {
                    let inconsistent: Bool = { if case .inconsistent = draft.numbers { return true } else { return false } }()
                    Text(note)
                        .font(.bodyMedium)
                        .foregroundStyle(inconsistent ? Palette.error : Palette.onSurfaceVariant)
                        .accessibilityIdentifier("numbering")
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func orderLabel(_ order: Order) -> String {
        switch order {
        case .numbers: return "By number"
        case .columns: return "Down columns"
        case .rows: return "Across rows"
        }
    }

    @ViewBuilder
    private func leftOutSection(draft: PhraseDraft, reviewLeftOut: [Entry], unreadSources: [DetectionSource],
                                list: ScrollViewProxy) -> some View {
        HStack {
            Text([
                reviewLeftOut.isEmpty ? nil : leftOutLine(draft: draft),
                unreadSources.isEmpty ? nil : "\(unreadSources.count) other detected regions",
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.bodyMedium)
                .foregroundStyle(Palette.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("left-out")
            Button(showLeftOut ? "Hide them" : "Show them") { showLeftOut.toggle() }
                .font(.labelLarge)
                .foregroundStyle(Palette.primary)
                .accessibilityIdentifier("show-left-out")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        if showLeftOut {
            ForEach(Array(reviewLeftOut.enumerated()), id: \.element.id) { i, entry in
                LeftOutRow(position: i, entry: entry, keepLabel: draft.restoreLabel(id: entry.id)) {
                    viewModel.restore(id: entry.id)
                }
            }
            ForEach(unreadSources, id: \.detectorId) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.reviewDescription).font(.bodyMedium)
                    Text("Not read as a separate word")
                        .font(.bodySmall)
                        .foregroundStyle(Palette.onSurfaceVariant)
                    Button("Show on photo") {
                        highlightedSource = source.detectorId
                        viewModel.highlighted = source.owner?.wordIndex.map { Int($0) }
                        withAnimation(Motion.state) { list.scrollTo("top", anchor: .top) }
                    }
                    .font(.labelLarge)
                    .foregroundStyle(Palette.primary)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("locate-source-\(source.detectorId)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .accessibilityIdentifier("unread-source-\(source.detectorId)")
            }
        }
    }
}

private func leftOutLine(draft: PhraseDraft) -> String {
    let reviewLeftOut = draft.reviewLeftOut
    let alternatives = reviewLeftOut.filter { draft.isAlternative(id: $0.id) }.count
    let leftOut = reviewLeftOut.filter { !draft.isAlternative(id: $0.id) }
    let apart = leftOut.filter { $0.source?.apart == true }.count
    let strays = leftOut.filter { $0.source?.stray == true }.count - apart
    let removed = leftOut.count - strays - apart
    func boxes(_ n: Int) -> String { "\(n) \(n == 1 ? "box" : "boxes")" }
    return [
        alternatives > 0 ? "\(boxes(alternatives)) kept as alternatives" : nil,
        strays > 0 ? "\(boxes(strays)) left out as not words" : nil,
        apart > 0 ? "\(boxes(apart)) left out as far from the words" : nil,
        removed > 0 ? "\(removed) \(removed == 1 ? "word" : "words") removed" : nil,
    ].compactMap { $0 }.joined(separator: " · ")
}

/**
 * A box left out: what the recogniser read and what the word model
 * made of it, and a way back into the phrase.
 */
private struct LeftOutRow: View {
    let position: Int
    let entry: Entry
    let keepLabel: String
    let onKeep: () -> Void

    var body: some View {
        if let source = entry.source {
            VStack(alignment: .leading, spacing: 4) {
                // The action gets its own line. Beside the fixed-width crop it used to
                // consume all remaining width at large fonts, hiding the source reading.
                HStack(spacing: 12) {
                    Crop(png: source.cropPng).frame(width: 96, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.raw.trimmingCharacters(in: .whitespaces).isEmpty ? "nothing read" : "read \"\(source.raw)\"")
                            .font(Typeface.mono(14, relativeTo: .callout))
                            .foregroundStyle(Palette.onSurfaceVariant)
                            .accessibilityIdentifier("left-out-\(position)-read")
                        Text("as a word: \(entry.word)")
                            .font(.bodySmall)
                            .foregroundStyle(Palette.onSurfaceVariant)
                            .accessibilityIdentifier("left-out-\(position)-word")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button(action: onKeep) {
                        Text(keepLabel).accessibilityIdentifier("keep-\(position)-label")
                    }
                    .font(.labelLarge)
                    .foregroundStyle(Palette.primary)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("keep-\(position)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .accessibilityIdentifier("left-out-\(position)")
        }
    }
}

/**
 * The photo fitted into a fixed height, every entry's box drawn over
 * it in its verdict's colour, the highlighted one heavier.
 */
struct PhotoWithBoxes: View {
    let photo: ResolvedPhoto
    let width: Int
    let height: Int
    let entries: [Entry]
    let leftOut: [Entry]
    let highlighted: Int?
    let unreadSources: [DetectionSource]
    let highlightedSource: UInt32?

    init(photo: ResolvedPhoto, width: Int, height: Int, entries: [Entry], leftOut: [Entry], highlighted: Int?,
         unreadSources: [DetectionSource], highlightedSource: UInt32?) {
        self.photo = photo
        self.width = width
        self.height = height
        self.entries = entries
        self.leftOut = leftOut
        self.highlighted = highlighted
        self.unreadSources = unreadSources
        self.highlightedSource = highlightedSource
    }

    var body: some View {
        // The whole-photo choice belongs to this photo: a new photo opens on the word area.
        BoxesOnPhoto(content: self).id(ObjectIdentifier(photo))
    }

    private struct BoxesOnPhoto: View {
        let content: PhotoWithBoxes
        @State private var wholePhoto = false

        var body: some View {
            let c = content
            let relevant = c.entries.compactMap { $0.source?.corners } +
                c.leftOut.filter { $0.id == c.highlighted }.compactMap { $0.source?.corners } +
                c.unreadSources.filter { $0.detectorId == c.highlightedSource }.map(\.corners)
            let bounds = wholePhoto ? ReviewPhotoBounds(left: 0, top: 0, width: c.width, height: c.height)
                : reviewPhotoBounds(frame: PhotoFrame(width: c.width, height: c.height), quads: relevant)
            VStack(alignment: .leading, spacing: 0) {
                WithPhotoBitmap(c.photo) { bitmap in
                    Canvas { context, size in
                        guard let image = bitmap else { return }
                        draw(image, bounds: bounds, in: &context, size: size)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color.black)
                    .accessibilityElement()
                    .accessibilityLabel(wholePhoto ? "Whole source photo with word confidence boxes"
                                        : "Word area of source photo with word confidence boxes")
                    .accessibilityIdentifier("photo")
                }
                Button(wholePhoto ? "Show word area" : "Show whole photo") { wholePhoto.toggle() }
                    .font(.labelLarge)
                    .foregroundStyle(Palette.primary)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("photo-context")
            }
        }

        private func draw(_ image: CGImage, bounds: ReviewPhotoBounds, in context: inout GraphicsContext, size: CGSize) {
            let c = content
            guard c.width > 0, c.height > 0,
                  let fit = fitPhoto(frame: PhotoFrame(width: bounds.width, height: bounds.height),
                                     width: Float(size.width), height: Float(size.height)) else { return }
            // The decoded preview can be downsampled; geometry remains in canonical pixels.
            let sx = Float(image.width) / Float(c.width)
            let sy = Float(image.height) / Float(c.height)
            func clamp(_ v: Int, _ low: Int, _ high: Int) -> Int { min(max(v, low), high) }
            let left = clamp(Int(Float(bounds.left) * sx), 0, image.width - 1)
            let top = clamp(Int(Float(bounds.top) * sy), 0, image.height - 1)
            let right = clamp(Int(Float(bounds.left + bounds.width) * sx), left + 1, image.width)
            let bottom = clamp(Int(Float(bounds.top + bounds.height) * sy), top + 1, image.height)
            if let cropped = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) {
                context.draw(Image(decorative: cropped, scale: 1), in: fit.rect)
            }
            context.clip(to: Path(fit.rect))
            let dx = Float(bounds.left)
            let dy = Float(bounds.top)
            // Source geometry is not a word reading: show its own polygon, never
            // enlarge a parent's old crop or invent classifier/confirmation state.
            for source in c.unreadSources where source.corners.count == 8 {
                let path = photoQuadPath(source.corners, fit, dx: dx, dy: dy)
                let selected = source.detectorId == c.highlightedSource
                context.stroke(path, with: .color(selected ? Palette.primary : LeftOut), lineWidth: selected ? 5 : 1)
            }
            for (entry, out) in c.entries.map({ ($0, false) }) + c.leftOut.map({ ($0, true) }) {
                guard let source = entry.source, source.corners.count == 8,
                      source.corners.allSatisfy(\.isFinite) else { continue }
                let path = photoQuadPath(source.corners, fit, dx: dx, dy: dy)
                let colour = out ? LeftOut : confidenceColour(entry: entry)
                let stroke: CGFloat = entry.id == c.highlighted ? 5 : out ? 1 : 2
                context.stroke(path, with: .color(colour), lineWidth: stroke)
            }
        }
    }
}

private struct InsertRow: View {
    let at: Int
    var missing: Int? = nil
    let onInsert: () -> Void

    var body: some View {
        HStack {
            if let missing {
                Text("Word \(missing) was not found: insert it here")
                    .font(.labelMedium)
                    .foregroundStyle(Palette.error)
                    .accessibilityIdentifier("missing-\(missing)")
            }
            Rectangle().fill(Palette.outlineVariant).frame(height: 1).frame(maxWidth: .infinity)
            Button(action: onInsert) {
                Image(systemName: "plus")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Insert a word at position \(at + 1)")
            .accessibilityIdentifier("insert-\(at)")
        }
        .padding(.horizontal, 24)
    }
}

struct WordRow: View {
    let number: Int
    let entry: Entry
    let showCrop: Bool
    let onClick: () -> Void
    let label: String
    let expectedWord: String?
    let acknowledged: Bool

    init(number: Int, entry: Entry, showCrop: Bool, onClick: @escaping () -> Void, label: String? = nil,
         expectedWord: String? = nil, acknowledged: Bool = false) {
        self.number = number
        self.entry = entry
        self.showCrop = showCrop
        self.onClick = onClick
        self.label = label ?? "\(number)."
        self.expectedWord = expectedWord
        self.acknowledged = acknowledged
    }

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.titleMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .frame(minWidth: 32, alignment: .leading)
                    .accessibilityIdentifier("row-\(number)-label")
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.word)
                        .font(Typeface.mono(22, relativeTo: .title3))
                        .foregroundStyle(Palette.onSurface)
                        .accessibilityIdentifier("row-\(number)-word")
                    let confidence = entry.modelConfidence
                    let confidenceText = confidence.map {
                        "Confidence " + String(format: "%.1f%%", locale: rootLocale, Double($0) * 100)
                    } ?? "Confidence unavailable"
                    ProgressView(value: Double(confidence ?? 0))
                        .tint(confidenceColour(entry: entry))
                        .padding(.vertical, 4)
                        .accessibilityLabel(confidenceText)
                        .accessibilityIdentifier("confidence-\(number)")
                    Text(confidenceText).font(.labelSmall).foregroundStyle(Palette.onSurface)
                    if showCrop {
                        if let source = entry.source {
                            Crop(png: source.cropPng)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .accessibilityIdentifier("crop-\(number)")
                        } else {
                            Text("Typed, not read from paper")
                                .font(.labelSmall)
                                .foregroundStyle(Palette.onSurfaceVariant)
                        }
                    } else {
                        if let note {
                            Text(note)
                                .font(.labelMedium)
                                .foregroundStyle(Palette.onSurface)
                                .accessibilityIdentifier("row-\(number)-note")
                        }
                        if let source = entry.source, source.fromRead && !entry.corrected {
                            Text("read: \(source.raw)").font(.labelMedium).foregroundStyle(Palette.onSurface)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let expectedWord {
                    let correct = entry.word == expectedWord
                    Text(correct ? "✓ Correct" : acknowledged ? "✗ Wrong\nAcknowledged" : "✗ Wrong")
                        .font(.labelMedium)
                        .foregroundStyle(correct ? Accepted : Palette.error)
                        .accessibilityIdentifier("match-\(number)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Review word \(number)")
        .accessibilityValue(entry.needsAttention ? "Needs attention" : "")
        .accessibilityIdentifier("row-\(number)")
    }

    private var note: String? {
        if entry.needsAttention { return "Needs attention" }
        if entry.corrected { return "Corrected" }
        if entry.typed { return "Typed" }
        if entry.source?.expandedFrom.isEmpty == false { return "Expanded word crop" }
        if entry.source?.joinedFrom.isEmpty == false { return "Joined from two pieces" }
        return nil
    }
}

/** A word's picture, fitted into whatever frame the caller gives it. */
struct Crop: View {
    let png: Data

    init(png: Data) { self.png = png }

    var body: some View {
        if let image = UIImage(data: png) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("What was written")
        }
    }
}

/** Material's FlowRow: children left to right, wrapping onto new lines. */
private struct FlowRow: SwiftUI.Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: LayoutSubviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/** Material's chips: a capsule that can be selected, or a plain suggestion. */
private struct Chip: View {
    let text: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                Text(text).font(.labelLarge)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(selected ? Palette.onPrimaryContainer : Palette.onSurfaceVariant)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Palette.primaryContainer : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.clear : Palette.outline))
        }
        .buttonStyle(.plain)
    }
}

private struct EditSheet: View {
    let viewModel: SheetViewModel
    let what: Editing
    let onDismiss: () -> Void
    var onLocate: (() -> Void)? = nil

    @State private var query = ""

    var body: some View {
        if let draft = viewModel.draft {
            let entry: Entry? = {
                if case let .word(id) = what { return draft.entries.first { $0.id == id } }
                return nil
            }()
            let number = entry.flatMap { e in draft.entries.firstIndex(of: e).map { $0 + 1 } }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry == nil ? "Insert a word" : "Word \(number ?? 0)")
                        .font(.titleMedium)
                        .accessibilityIdentifier("edit-word-title")
                    if let entry, let source = entry.source {
                        Crop(png: source.cropPng)
                            .frame(maxWidth: .infinity)
                            .frame(height: 72)
                            .accessibilityIdentifier("word-crop")
                        OcrEvidence(source: source)
                        Text("Read as \"\(source.read)\", " +
                             String(format: "%.1f%%", locale: rootLocale, Double(source.confidence) * 100) +
                             " likely. Other possibilities, likeliest first:")
                            .font(.bodyMedium)
                            .accessibilityIdentifier("word-confidence")
                        if let onLocate {
                            Button("Locate on source photo", action: onLocate)
                                .font(.labelLarge)
                                .foregroundStyle(Palette.primary)
                                .accessibilityIdentifier("locate-word")
                        }
                        FlowRow {
                            ForEach(Array(([(source.read, source.confidence)] + source.alternatives).enumerated()),
                                    id: \.offset) { _, option in
                                Chip(text: "\(option.0) \(Int(option.1 * 100))%", selected: entry.word == option.0) {
                                    choose(option.0)
                                }
                                .accessibilityIdentifier("alt-\(option.0)")
                            }
                        }
                    } else if entry != nil {
                        Text("Typed, not read from the sheet.").font(.bodyMedium)
                    }
                    TextField("Find a word in the list", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .accessibilityIdentifier("search")
                    FlowRow {
                        ForEach(matches, id: \.self) { word in
                            Chip(text: word) { choose(word) }
                                .accessibilityIdentifier("pick-\(word)")
                        }
                    }
                    if let entry {
                        Button {
                            viewModel.remove(id: entry.id)
                            onDismiss()
                        } label: {
                            Label("Remove this word", systemImage: "trash")
                        }
                        .font(.labelLarge)
                        .foregroundStyle(Palette.primary)
                        .accessibilityIdentifier("remove")
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .background(Palette.surface)
            .foregroundStyle(Palette.onSurface)
        }
    }

    private var matches: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : Array(listWords(prefix: trimmed).prefix(12))
    }

    private func choose(_ word: String) {
        switch what {
        case let .word(id): viewModel.change(id: id, word: word)
        case let .insert(at, number): viewModel.insert(at: at, word: word, number: number)
        }
        onDismiss()
    }
}

/** Literal reads always appear with their own crop, not the matching transform. */
private struct OcrEvidence: View {
    let source: Source
    @State private var expanded = false

    var body: some View {
        Text(source.raw.trimmingCharacters(in: .whitespaces).isEmpty ? "No text read from this crop"
             : "Read as: \(source.raw)")
            .font(.bodyMedium)
            .accessibilityIdentifier("current-ocr")
        if let m = source.matching, m.original || m.removedPrefixBytes > 0 {
            Text("Matching text: \(m.text)" +
                 (m.removedPrefixBytes > 0 ? " · label prefix removed" : "") +
                 (m.original ? " · from original crop" : " · from this crop"))
                .font(.bodySmall)
                .accessibilityIdentifier("matching-evidence")
        }
        if !source.labels.isEmpty {
            Text("Label observations: " + source.labels.map {
                "\($0.literal) (\($0.ordinal.map(String.init) ?? "number unknown")\($0.ambiguous ? ", attachment unclear" : ""))"
            }.joined(separator: "; ") + (source.labelConflict ? ". Conflicting numbers; check the order." : ""))
                .font(.bodySmall)
                .accessibilityIdentifier("label-evidence")
        }
        if let original = source.originalOcr {
            Button(expanded ? "Hide original OCR" : "Show original OCR") { expanded.toggle() }
                .font(.labelLarge)
                .foregroundStyle(Palette.primary)
                .accessibilityIdentifier("original-ocr-toggle")
            if expanded {
                Crop(png: original.cropPng)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .accessibilityIdentifier("original-ocr-crop")
                Text("Original crop read as: \(original.raw)")
                    .font(.bodyMedium)
                    .accessibilityIdentifier("original-ocr-text")
            }
        }
    }
}
