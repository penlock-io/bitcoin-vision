import Foundation

enum Order: CaseIterable, Hashable {
    case numbers, columns, rows

    /** Kotlin's `Order.entries`, in declaration order. */
    static var entries: [Order] { allCases }
}

/** What the item numbers written beside the words made of the page. */
enum Numbers: Equatable {
    case none

    /**
     * The numbers read as a run 1..[count]: [missing] are the numbers no
     * word carries, [outOfPlace] the numbers not where the page puts
     * them, [unresolved] how many words carry a number that could not
     * be placed in the run.
     */
    case held(count: Int, missing: [Int], outOfPlace: [Int], unresolved: Int)

    case inconsistent(detail: String)
}

/** Original keep state before an extent expansion hid this observation. */
struct ExpansionParent: Equatable, Hashable {
    let id: Int
    let stray: Bool
}

struct OriginalOcr: Equatable {
    let corners: [Float]
    let cropPng: Data
    let raw: String
}

struct MatchingText: Equatable {
    let text: String
    let original: Bool
    let removedPrefixBytes: Int
}

struct ObservedLabel: Equatable {
    let literal: String
    let ordinal: Int?
    let origin: String
    let ambiguous: Bool
    var corners: [Float] = []
}

/** A word box the sheet was read from, as the review needs it. Compared by identity, as in Kotlin. */
final class Source {
    /** Four corners in photo pixels, x1, y1, ... x4, y4. */
    let corners: [Float]
    /** The word model's own ranked list words with probabilities, best first. */
    let ranked: [(String, Float)]
    /** Confident enough in [read] not to ask the person to check it. */
    let accepted: Bool
    let cropPng: Data
    /** The word the phone shows first: the pick over the recogniser's read and the model's five. */
    let read: String
    /** The recogniser's raw read, empty without one. */
    let raw: String
    /** Not a word by the phone's reckoning: left out until put back. */
    let stray: Bool
    /** The item number the page's numbering gives the word, if any. */
    let number: Int?
    /** A word by its read but far from the phrase: a stray for where it sits. */
    let apart: Bool
    /** Original pieces of this union; mutually exclusive with the joined word. */
    let joinedFrom: [Int]
    /** One or two originals of an expanded crop; distinct from a native join. */
    let expandedFrom: [ExpansionParent]
    /** The chance [read] is right. */
    let confidence: Float
    /** Other words to offer in place of [read], likeliest first, with their chances. */
    let alternatives: [(String, Float)]
    let originalOcr: OriginalOcr?
    let matching: MatchingText?
    let labels: [ObservedLabel]
    let labelConflict: Bool

    init(
        corners: [Float],
        ranked: [(String, Float)],
        accepted: Bool,
        cropPng: Data,
        read: String,
        raw: String = "",
        stray: Bool = false,
        number: Int? = nil,
        apart: Bool = false,
        joinedFrom: [Int] = [],
        expandedFrom: [ExpansionParent] = [],
        confidence: Float = 0,
        alternatives: [(String, Float)] = [],
        originalOcr: OriginalOcr? = nil,
        matching: MatchingText? = nil,
        labels: [ObservedLabel] = [],
        labelConflict: Bool = false
    ) {
        self.corners = corners
        self.ranked = ranked
        self.accepted = accepted
        self.cropPng = cropPng
        self.read = read
        self.raw = raw
        self.stray = stray
        self.number = number
        self.apart = apart
        self.joinedFrom = joinedFrom
        self.expandedFrom = expandedFrom
        self.confidence = confidence
        self.alternatives = alternatives
        self.originalOcr = originalOcr
        self.matching = matching
        self.labels = labels
        self.labelConflict = labelConflict
    }

    var replacementParents: [Int] { expandedFrom.isEmpty ? joinedFrom : expandedFrom.map(\.id) }

    var probability: Float { ranked[0].1 }

    /** The pick came from the recogniser's read, not the model's top. */
    var fromRead: Bool { read != ranked[0].0 }
}

/**
 * One word of the phrase under review: read from a box, or typed. A
 * typed word may carry the item number of the gap it fills.
 */
struct Entry: Equatable {
    var id: Int
    var word: String
    var source: Source?
    var checked: Bool
    var number: Int? = nil

    var typed: Bool { source == nil }
    var corrected: Bool { if let source { return word != source.read } else { return false } }

    static func == (lhs: Entry, rhs: Entry) -> Bool {
        lhs.id == rhs.id && lhs.word == rhs.word && lhs.source === rhs.source &&
            lhs.checked == rhs.checked && lhs.number == rhs.number
    }
}

private struct Typed {
    let id: Int
    let after: Int
    var number: Int? = nil
}

/**
 * The phrase as the person is shaping it from a read sheet. A draft
 * is immutable: every edit returns the next draft, so a check is
 * only ever true of the exact word it was given.
 *
 * A read word keeps its box's identity through every edit. A typed
 * word is anchored behind the box it was inserted after (or at the
 * start), so it keeps its place when the reading order switches.
 */
final class PhraseDraft {
    private static let START = -1

    /** Box ids are their indices in the scan's words. */
    private let boxes: [Source]
    private let columns: [Int]
    private let rows: [Int]
    private let byNumber: [Int]
    /** What the scan made of the page's numbers, as read: provenance, not the state of the draft. */
    let scanNumbers: Numbers
    let listNumbered: Bool
    let order: Order
    let orderRequiresReview: Bool
    private let removed: Set<Int>
    private let chosen: [Int: String]
    private let typed: [Typed]
    private let checked: Set<Int>
    private let nextId: Int

    let entries: [Entry]

    /** The boxes left out, strays and removed words alike, in the current order, each as it would return. */
    let leftOut: [Entry]

    private init(
        boxes: [Source], columns: [Int], rows: [Int], byNumber: [Int], scanNumbers: Numbers, listNumbered: Bool,
        order: Order, orderRequiresReview: Bool, removed: Set<Int>, chosen: [Int: String], typed: [Typed],
        checked: Set<Int>, nextId: Int
    ) {
        self.boxes = boxes
        self.columns = columns
        self.rows = rows
        self.byNumber = byNumber
        self.scanNumbers = scanNumbers
        self.listNumbered = listNumbered
        self.order = order
        self.orderRequiresReview = orderRequiresReview
        self.removed = removed
        self.chosen = chosen
        self.typed = typed
        self.checked = checked
        self.nextId = nextId

        let sequence: [Int]
        switch order {
        case .numbers: sequence = byNumber
        case .columns: sequence = columns
        case .rows: sequence = rows
        }
        func entry(_ id: Int, _ source: Source?, _ number: Int?) -> Entry {
            Entry(id: id, word: chosen[id] ?? source!.read, source: source, checked: checked.contains(id), number: number)
        }
        var built: [Entry] = []
        for t in typed where t.after == Self.START { built.append(entry(t.id, nil, t.number)) }
        for box in sequence {
            if !removed.contains(box) { built.append(entry(box, boxes[box], boxes[box].number)) }
            for t in typed where t.after == box { built.append(entry(t.id, nil, t.number)) }
        }
        entries = built
        leftOut = sequence.filter { removed.contains($0) }.map {
            Entry(id: $0, word: chosen[$0] ?? boxes[$0].read, source: boxes[$0], checked: false)
        }
    }

    /**
     * Strays start left out; `leftOut` lists them and `restore` puts one
     * back. A word the model is sure of starts ticked; the person's work
     * is the uncertain ones, and every tick stays theirs to undo.
     * Kotlin's defaults: [byNumber] is [columns], and [listNumbered] is
     * whether [numbers] is anything but none.
     */
    convenience init(
        boxes: [Source],
        columns: [Int],
        rows: [Int],
        order: Order,
        byNumber: [Int]? = nil,
        numbers: Numbers = .none,
        listNumbered: Bool? = nil,
        orderRequiresReview: Bool = false
    ) {
        self.init(
            boxes: boxes, columns: columns, rows: rows, byNumber: byNumber ?? columns, scanNumbers: numbers,
            listNumbered: listNumbered ?? (numbers != .none), order: order, orderRequiresReview: orderRequiresReview,
            removed: Set(boxes.indices.filter { boxes[$0].stray }), chosen: [:], typed: [],
            checked: orderRequiresReview ? [] : Self.confident(boxes), nextId: boxes.count
        )
    }

    /** The boxes that open ticked: read with confidence, and words at all. */
    private static func confident(_ boxes: [Source]) -> Set<Int> {
        Set(boxes.indices.filter { boxes[$0].accepted && !boxes[$0].stray })
    }

    private func box(_ id: Int) -> Source? { boxes.indices.contains(id) ? boxes[id] : nil }

    /** Whether the page's numbers were read as a run, so `Order.numbers` means something. */
    var numbered: Bool { if case .held = scanNumbers { return true } else { return false } }

    /**
     * The page's numbers as the draft now stands: a number the scan
     * found no word for is missing until a typed word fills its gap,
     * and missing again when that word goes.
     */
    var numbers: Numbers {
        guard case let .held(count, missing, outOfPlace, unresolved) = scanNumbers else { return scanNumbers }
        let carried = Set(entries.compactMap(\.number))
        return .held(count: count, missing: missing.filter { !carried.contains($0) }, outOfPlace: outOfPlace,
                     unresolved: unresolved)
    }

    var words: [String] { entries.map(\.word) }

    /**
     * Where each number the page's run lacks belongs among the entries,
     * read by number: the index at which a word carrying it would be
     * inserted, before the first entry whose number is higher. Several
     * missing numbers at one place name the lowest. Under either
     * geometric order the place is no one's to say, and there is none.
     */
    func missingAt() -> [Int: Int] {
        guard case let .held(_, missing, _, _) = numbers, order == .numbers else { return [:] }
        var out: [Int: Int] = [:]
        for k in missing.sorted() {
            let at = entries.firstIndex { ($0.number ?? Int.max) > k } ?? entries.count
            if out[at] == nil { out[at] = k }
        }
        return out
    }

    var allChecked: Bool { !entries.isEmpty && entries.allSatisfy(\.checked) }

    func change(id: Int, word: String) -> PhraseDraft {
        var chosen = self.chosen
        chosen[id] = word
        var checked = self.checked
        checked.remove(id)
        return copy(chosen: chosen, checked: checked)
    }

    func remove(id: Int) -> PhraseDraft {
        var chosen = self.chosen
        chosen.removeValue(forKey: id)
        var checked = self.checked
        checked.remove(id)
        return copy(
            removed: box(id) != nil ? removed.union([id]) : removed,
            chosen: chosen,
            typed: typed.filter { $0.id != id },
            checked: checked
        )
    }

    /**
     * Inserts a typed word so that it becomes entry `at`, unchecked.
     * With [number], the word fills that gap in the page's run and
     * carries the number from then on; without, it carries none, even
     * at a gap's place.
     */
    func insert(at: Int, word: String, number: Int? = nil) -> PhraseDraft {
        let id = nextId
        let previous = entries.indices.contains(at - 1) ? entries[at - 1] : nil
        var list = typed
        if let previous {
            if previous.typed {
                let i = list.firstIndex { $0.id == previous.id }!
                list.insert(Typed(id: id, after: list[i].after, number: number), at: i + 1)
            } else {
                let i = list.firstIndex { $0.after == previous.id }
                list.insert(Typed(id: id, after: previous.id, number: number), at: i ?? list.count)
            }
        } else {
            list.insert(Typed(id: id, after: Self.START, number: number), at: 0)
        }
        var chosen = self.chosen
        chosen[id] = word
        return copy(chosen: chosen, typed: list, nextId: nextId + 1)
    }

    /** Restore an interpretation, unchecked, never a replacement and its originals together. */
    func restore(id: Int) -> PhraseDraft {
        guard let source = box(id) else { return self }
        if !source.replacementParents.isEmpty {
            let pieces = Set(source.replacementParents)
            return copy(removed: removed.union(pieces).subtracting([id]), checked: checked.subtracting(pieces).subtracting([id]))
        }
        if let found = replacementOf(id) {
            let (key, replacement) = found
            let pieces = Set(replacement.replacementParents)
            // Once the original interpretation is selected, an explicitly
            // restored stray may be kept individually, just like other strays.
            // Native joins retain their existing whole-pair restoration rule.
            if !replacement.expandedFrom.isEmpty && removed.contains(key) {
                return copy(removed: removed.subtracting([id]), checked: checked.subtracting(pieces).subtracting([key]))
            }
            let originallyStray = Set(replacement.expandedFrom.filter(\.stray).map(\.id))
            return copy(
                removed: removed.union([key]).subtracting(pieces).union(originallyStray),
                checked: checked.subtracting(pieces).subtracting([key])
            )
        }
        return copy(removed: removed.subtracting([id]), checked: checked.subtracting([id]))
    }

    private func replacementOf(_ id: Int) -> (Int, Source)? {
        for (key, source) in boxes.enumerated() where source.replacementParents.contains(id) { return (key, source) }
        return nil
    }

    /** Whether a box belongs to mutually exclusive original/replacement interpretations. */
    func isAlternative(id: Int) -> Bool {
        (box(id).map { !$0.replacementParents.isEmpty } ?? false) || replacementOf(id) != nil
    }

    /** Name the full effect of restoration when it swaps interpretations. */
    func restoreLabel(id: Int) -> String {
        let source = box(id)
        if source?.expandedFrom.isEmpty == false { return "Use expanded word" }
        if source?.joinedFrom.isEmpty == false { return "Use joined word" }
        guard let found = replacementOf(id) else { return "Keep as a word" }
        let (key, replacement) = found
        if replacement.expandedFrom.isEmpty { return "Use original parts" }
        if removed.contains(key) { return "Keep as a word" }
        if replacement.expandedFrom.count == 1 { return "Use original word" }
        return "Use original parts"
    }

    /**
     * Recognition confidence cannot confirm a new position. Preserve checks
     * only for entries that stay in exactly the same position; never re-tick.
     */
    func reorder(order: Order) -> PhraseDraft {
        if order == self.order { return self }
        let reordered = copy(order: order, orderRequiresReview: true)
        var unchanged = Set<Int>()
        for (position, entry) in reordered.entries.enumerated()
        where entries.indices.contains(position) && entries[position].id == entry.id {
            unchanged.insert(entry.id)
        }
        return reordered.copy(checked: checked.intersection(unchanged))
    }

    func check(id: Int, on: Bool) -> PhraseDraft {
        copy(checked: on ? checked.union([id]) : checked.subtracting([id]))
    }

    private func copy(
        order: Order? = nil,
        orderRequiresReview: Bool? = nil,
        removed: Set<Int>? = nil,
        chosen: [Int: String]? = nil,
        typed: [Typed]? = nil,
        checked: Set<Int>? = nil,
        nextId: Int? = nil
    ) -> PhraseDraft {
        PhraseDraft(
            boxes: boxes, columns: columns, rows: rows, byNumber: byNumber, scanNumbers: scanNumbers,
            listNumbered: listNumbered, order: order ?? self.order,
            orderRequiresReview: orderRequiresReview ?? self.orderRequiresReview,
            removed: removed ?? self.removed, chosen: chosen ?? self.chosen, typed: typed ?? self.typed,
            checked: checked ?? self.checked, nextId: nextId ?? self.nextId
        )
    }
}

/** A worksheet strip holds one phrase of this many words. */
let WORKSHEET_WORDS = 12

private func named(_ numbers: [Int]) -> String {
    if numbers.count == 1 { return "word \(numbers[0])" }
    return "words " + numbers.dropLast().map(String.init).joined(separator: ", ") + " and \(numbers.last!)"
}

/**
 * The review's status line. Passing is well formed, never right. A
 * number the page's run lacks is named before anything else; a phrase
 * that passes carries its ticks.
 */
func phraseStatus(count: Int, passes: Bool, numbers: Numbers = .none, ticked: Int? = nil,
                  orderNeedsReview: Bool = false) -> String {
    let status: String
    if case let .held(_, missing, _, _) = numbers, !missing.isEmpty {
        status = "\(count) words: \(named(missing)) \(missing.count == 1 ? "was" : "were") not found"
    } else if count == WORKSHEET_WORDS && passes {
        status = "\(count) words · checksum passes" + (ticked.map { " · \($0) of \(count) ticked" } ?? "")
    } else if count == WORKSHEET_WORDS {
        status = "\(count) words · checksum fails: review the words"
    } else if count == WORKSHEET_WORDS - 1 {
        status = "\(count) words: a word is missing"
    } else if count == WORKSHEET_WORDS + 1 {
        status = "\(count) words: one word too many"
    } else {
        status = "\(count) words: this worksheet holds a \(WORKSHEET_WORDS)-word phrase"
    }
    return status + (orderNeedsReview ? " · check word order against paper" : "")
}

/**
 * What the page's numbers left open, for the review to say under the
 * order; nothing when they were read as a complete run or not at all.
 * Kotlin's default: [listNumbered] is whether [numbers] is anything but none.
 */
func numberingNote(numbers: Numbers, listNumbered: Bool? = nil) -> String? {
    switch numbers {
    case .none:
        return (listNumbered ?? false)
            ? "Numbered list detected. Some numbers could not be resolved; check the reading order." : nil
    case .inconsistent:
        return "The numbers on the page contradict each other, so the words are in the order they sit on the page."
    case let .held(_, _, outOfPlace, unresolved):
        var parts: [String] = []
        if !outOfPlace.isEmpty {
            let one = outOfPlace.count == 1
            parts.append("\(one ? "Number" : "Numbers") \(outOfPlace.map(String.init).joined(separator: ", ")) " +
                "\(one ? "is" : "are") not where the page puts \(one ? "it" : "them"): check the order.")
        }
        if unresolved > 0 {
            parts.append("A number beside \(unresolved) \(unresolved == 1 ? "word" : "words") could not be read.")
        }
        let note = parts.joined(separator: " ")
        return note.isEmpty ? nil : note
    }
}
