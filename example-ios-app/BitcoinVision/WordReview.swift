import Foundation

extension Entry {
    /** The scanner's existing verdict, unless the person has replaced that read. */
    var needsAttention: Bool { source?.accepted == false && !corrected }

    /**
     * The scanner's chance that this displayed word is right, for the read or
     * any alternative it offered; nil for a word it never offered.
     */
    var modelConfidence: Float? {
        guard let s = source else { return nil }
        let chance = word == s.read ? s.confidence : s.alternatives.first { $0.0 == word }?.1
        guard let chance, chance.isFinite, (0...1).contains(chance) else { return nil }
        return chance
    }

    /** Only suppress already-excluded, unambiguous standalone labels, never word prefixes. */
    var isObviousNumberLabel: Bool {
        guard let s = source else { return false }
        if !s.stray || corrected || s.labelConflict || s.labels.contains(where: \.ambiguous) { return false }
        guard let match = s.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: #/([0-9]{1,2})[.)]/#), let ordinal = Int(match.1) else { return false }
        return (1...24).contains(ordinal)
    }
}

extension PhraseDraft {
    var reviewLeftOut: [Entry] { leftOut.filter { !($0.isObviousNumberLabel && !isAlternative(id: $0.id)) } }
}

struct ReviewPhotoBounds: Equatable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
}

private func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T { min(max(value, low), high) }

/** Display-only crop in canonical photo coordinates. Never changes recognition input. */
func reviewPhotoBounds(frame: PhotoFrame, quads: [[Float]]) -> ReviewPhotoBounds {
    let width = max(frame.width, 1)
    let height = max(frame.height, 1)
    let full = ReviewPhotoBounds(left: 0, top: 0, width: width, height: height)
    let valid = quads.filter { $0.count == 8 && $0.allSatisfy(\.isFinite) }
    if valid.isEmpty { return full }
    let xs = valid.flatMap { [$0[0], $0[2], $0[4], $0[6]] }
    let ys = valid.flatMap { [$0[1], $0[3], $0[5], $0[7]] }
    let minX = clamp(xs.min()!, 0, Float(width))
    let maxX = clamp(xs.max()!, 0, Float(width))
    let minY = clamp(ys.min()!, 0, Float(height))
    let maxY = clamp(ys.max()!, 0, Float(height))
    if maxX <= minX || maxY <= minY { return full }
    let margin = max(4, max(maxX - minX, maxY - minY) * 0.04)
    let left = clamp(Int((minX - margin).rounded(.down)), 0, width - 1)
    let top = clamp(Int((minY - margin).rounded(.down)), 0, height - 1)
    let right = clamp(Int((maxX + margin).rounded(.up)), left + 1, width)
    let bottom = clamp(Int((maxY + margin).rounded(.up)), top + 1, height)
    return ReviewPhotoBounds(left: left, top: top, width: right - left, height: bottom - top)
}

extension WordReading {
    func reviewSource() -> Source {
        Source(
            corners: corners, ranked: ranked.map { ($0.word, $0.probability) }, accepted: accepted, cropPng: cropPng,
            read: read, raw: raw, stray: stray, number: number.map { Int($0) }, apart: apart,
            joinedFrom: joinedFrom.map { Int($0) },
            expandedFrom: expandedFrom.map { ExpansionParent(id: Int($0.wordIndex), stray: $0.stray) },
            confidence: confidence,
            alternatives: alternatives.map { ($0.word, $0.confidence) },
            originalOcr: originalOcr.map { OriginalOcr(corners: $0.corners, cropPng: $0.cropPng, raw: $0.raw) },
            matching: matching.map {
                MatchingText(text: $0.text, original: $0.original, removedPrefixBytes: Int($0.removedPrefixBytes))
            },
            labels: labels.map {
                ObservedLabel(literal: $0.literal, ordinal: $0.ordinal.map { Int($0) }, origin: $0.origin,
                              ambiguous: $0.ambiguous, corners: $0.corners)
            },
            labelConflict: labelConflict
        )
    }
}
