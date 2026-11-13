import XCTest
@testable import BitcoinVision

private let zeros: [Float] = Array(repeating: 0, count: 8)

private extension PhraseDraft {
    func checkAll() -> PhraseDraft { entries.reduce(self) { $0.check(id: $1.id, on: true) } }
}

final class PhraseDraftTests: XCTestCase {
    private func source(_ word: String, accepted: Bool = true, stray: Bool = false, read: String? = nil,
                        number: Int? = nil) -> Source {
        Source(corners: zeros, ranked: [(word, 0.9), ("zoo", 0.05)], accepted: accepted, cropPng: Data(),
               read: read ?? word, raw: read ?? word, stray: stray, number: number)
    }

    func test_passing_checksum_does_not_tick_nine_accepted_words_when_order_requires_review() {
        let words = ["close", "transfer", "orange", "absorb", "figure", "between",
                     "pen", "tobacco", "exist", "outside", "equip", "spare"]
        let d = PhraseDraft(boxes: words.map { source($0, accepted: !["close", "pen", "spare"].contains($0)) },
                            columns: [0, 2, 4, 6, 8, 10, 1, 3, 5, 7, 9, 11],
                            rows: Array(words.indices), order: .rows, orderRequiresReview: true)
        XCTAssertTrue(d.entries.allSatisfy { !$0.checked })
        XCTAssertFalse(d.allChecked)
        XCTAssertEqual("12 words · checksum passes · 0 of 12 ticked · check word order against paper",
                       phraseStatus(count: 12, passes: true, ticked: 0,
                                    orderNeedsReview: d.orderRequiresReview && !d.allChecked))
        let checked = d.checkAll()
        XCTAssertTrue(checked.allChecked)
        XCTAssertEqual(checked.entries, checked.reorder(order: .rows).entries)
        XCTAssertFalse(checked.reorder(order: .columns).allChecked)
        XCTAssertTrue(checked.reorder(order: .columns).entries.first!.checked)
        XCTAssertTrue(checked.reorder(order: .columns).entries.last!.checked)
        XCTAssertTrue(checked.reorder(order: .columns).entries.dropFirst().dropLast().allSatisfy { !$0.checked })
    }

    func test_page22_geometric_default_preserves_word_uncertainty_and_manual_transpose() {
        let words = ["close", "orange", "figure", "pen", "exist", "equip",
                     "transfer", "absorb", "between", "tobacco", "outside", "spare"]
        let d = PhraseDraft(boxes: words.map { source($0, accepted: !["close", "pen", "spare"].contains($0)) },
                            columns: Array(words.indices), rows: [0, 6, 1, 7, 2, 8, 3, 9, 4, 10, 5, 11],
                            order: .columns, orderRequiresReview: false)
        XCTAssertEqual(words, d.words)
        XCTAssertEqual(9, d.entries.filter(\.checked).count)
        XCTAssertFalse(d.allChecked)
        XCTAssertEqual("12 words · checksum fails: review the words", phraseStatus(count: 12, passes: false))
        let transposed = d.reorder(order: .rows)
        XCTAssertEqual(["close", "transfer", "orange", "absorb", "figure", "between",
                        "pen", "tobacco", "exist", "outside", "equip", "spare"], transposed.words)
        XCTAssertTrue(transposed.entries.allSatisfy { !$0.checked })
        XCTAssertTrue(transposed.orderRequiresReview)
    }

    func test_near_tie_default_opens_unticked_and_manual_transpose_stays_available() {
        let words = ["fun", "soldier", "lock", "fix", "onion", "afford",
                     "sibling", "order", "all", "report", "injury", "habit"]
        let d = PhraseDraft(boxes: words.map { source($0, accepted: $0 != "all") },
                            columns: Array(words.indices), rows: [0, 4, 8, 1, 5, 9, 2, 6, 10, 3, 7, 11],
                            order: .columns, orderRequiresReview: true)
        XCTAssertEqual(words, d.words) // Longest-dimension default is NOT changed.
        XCTAssertTrue(d.entries.allSatisfy { !$0.checked })
        XCTAssertEqual("12 words · checksum fails: review the words · check word order against paper",
                       phraseStatus(count: 12, passes: false, orderNeedsReview: d.orderRequiresReview))
        let rows = d.reorder(order: .rows)
        XCTAssertEqual(["fun", "onion", "all", "soldier", "afford", "report",
                        "lock", "sibling", "injury", "fix", "order", "habit"], rows.words)
        XCTAssertTrue(rows.entries.allSatisfy { !$0.checked })
        XCTAssertFalse(rows.allChecked)
        XCTAssertTrue(rows.checkAll().allChecked)
    }

    func test_selected_word_confidence_controls_story_and_unlock_ticks_in_both_orders() {
        let story = Source(corners: zeros, ranked: [("history", 0.9947837), ("victory", 0.002336808)],
                           accepted: false, cropPng: Data(), read: "story", raw: "12.SToRy",
                           matching: MatchingText(text: "12.SToRy", original: false, removedPrefixBytes: 0))
        let unlock = Source(corners: Array(repeating: 1, count: 8), ranked: [("unlock", 0.9999974), ("under", 0.0000009745443)],
                            accepted: true, cropPng: Data(), read: "unlock", raw: "unlock")
        let draft = PhraseDraft(boxes: [story, unlock], columns: [0, 1], rows: [1, 0], order: .columns)
        for d in [draft, draft.reorder(order: .rows)] {
            XCTAssertFalse(d.entries.first { $0.id == 0 }!.checked)
            XCTAssertEqual(d.order == .columns, d.entries.first { $0.id == 1 }!.checked)
            XCTAssertEqual("story", d.entries.first { $0.id == 0 }!.word)
            XCTAssertFalse(d.allChecked)
        }
        XCTAssertTrue(draft.check(id: 0, on: true).allChecked)
        // Existing reorder policy rechecks uncertain words; editing invalidates a check.
        XCTAssertFalse(draft.check(id: 0, on: true).reorder(order: .rows).entries.first { $0.id == 0 }!.checked)
        XCTAssertFalse(draft.change(id: 1, word: "unfold").entries.first { $0.id == 1 }!.checked)
    }

    func test_list_mode_and_ocr_provenance_survive_edits_without_inventing_number_order() {
        let original = OriginalOcr(corners: Array(repeating: 1, count: 8), cropPng: Data([1]), raw: "9.Hobby")
        let word = Source(corners: Array(repeating: 2, count: 8), ranked: [("hobby", 0.9)], accepted: true,
                          cropPng: Data([2]), read: "hobby", raw: ". Hobby", originalOcr: original,
                          matching: MatchingText(text: "Hobby", original: true, removedPrefixBytes: 2),
                          labels: [ObservedLabel(literal: "9.Hobby", ordinal: 9, origin: "prefix", ambiguous: false)])
        let draft = PhraseDraft(boxes: [word, source("state")], columns: [0, 1], rows: [1, 0],
                                order: .columns, listNumbered: true)
        XCTAssertTrue(draft.listNumbered)
        XCTAssertFalse(draft.numbered)
        XCTAssertTrue(numberingNote(numbers: draft.numbers, listNumbered: draft.listNumbered)!
            .contains("check the reading order"))
        let changed = draft.change(id: 0, word: "happy").reorder(order: .rows)
        XCTAssertTrue(changed.listNumbered)
        let entry = changed.entries.first { $0.id == 0 }!
        XCTAssertFalse(entry.checked)
        XCTAssertEqual(". Hobby", entry.source!.raw)
        XCTAssertEqual(original, entry.source!.originalOcr)
        XCTAssertEqual("Hobby", entry.source!.matching!.text)
        XCTAssertNil(entry.number)
    }

    func test_joined_words_and_original_pieces_are_reversible_but_never_active_together() {
        let joined = Source(corners: zeros, ranked: [("transfer", 0.999)], accepted: true,
                            cropPng: Data(), read: "transfer", joinedFrom: [0, 2])
        let sources = [source("track", accepted: false, stray: true), joined,
                       source("fee", accepted: false, stray: true), source("last")]
        let d = PhraseDraft(boxes: sources, columns: [0, 1, 2, 3], rows: [3, 0, 1, 2], order: .columns)
        XCTAssertEqual(["transfer", "last"], d.words)
        XCTAssertEqual("Use original parts", d.restoreLabel(id: 0))
        XCTAssertEqual("Use joined word", d.restoreLabel(id: 1))
        XCTAssertEqual("Keep as a word", d.restoreLabel(id: 3))
        XCTAssertTrue(d.isAlternative(id: 2))
        for piece in [0, 2] {
            let split = d.restore(id: piece)
            XCTAssertEqual(["track", "fee", "last"], split.words)
            XCTAssertEqual([1], split.leftOut.map(\.id))
            XCTAssertTrue(split.entries.prefix(2).allSatisfy { !$0.checked })
            XCTAssertEqual(["last", "track", "fee"], split.reorder(order: .rows).words)
            let back = split.change(id: 0, word: "train").restore(id: 1)
            XCTAssertEqual(["transfer", "last"], back.words)
            XCTAssertFalse(back.entries.first!.checked)
            XCTAssertEqual(["train", "fee", "last"], back.restore(id: 2).words)
            // Removing a union does not silently select a different interpretation.
            XCTAssertEqual(["last"], d.remove(id: 1).words)
            XCTAssertEqual(["track", "fee", "last"], d.remove(id: 1).restore(id: piece).words)
        }
    }

    func test_expanded_pairs_restore_prior_strays_both_orders_and_keep_corrections_without_ticks() {
        for originalStrays in [[false, false], [false, true], [true, true]] {
            let expanded = Source(corners: Array(repeating: 4, count: 8), ranked: [("later", 0.7)], accepted: false,
                                  cropPng: Data([1, 2]), read: "later", raw: "laler",
                                  expandedFrom: [ExpansionParent(id: 0, stray: originalStrays[0]),
                                                 ExpansionParent(id: 2, stray: originalStrays[1])])
            let sources = [source("ten", accepted: false, stray: true), expanded,
                           source("fee", accepted: false, stray: true), source("last")]
            for order in [Order.columns, Order.rows] {
                let d = PhraseDraft(boxes: sources, columns: [0, 1, 2, 3], rows: [3, 0, 1, 2], order: order)
                XCTAssertFalse(d.entries.first { $0.id == 1 }!.checked)
                XCTAssertTrue(d.isAlternative(id: 0) && d.isAlternative(id: 1) && d.isAlternative(id: 2))
                XCTAssertEqual("Use original parts", d.restoreLabel(id: 0))
                XCTAssertEqual("Use expanded word", d.restoreLabel(id: 1))
                XCTAssertTrue(expanded.joinedFrom.isEmpty)
                let originals = d.check(id: 1, on: true).restore(id: 0)
                let expectedIds = [0, 2].enumerated().filter { !originalStrays[$0.offset] }.map(\.element)
                XCTAssertEqual(Set(expectedIds).union([3]), Set(originals.entries.map(\.id)))
                XCTAssertTrue(originals.entries.filter { $0.id != 3 }.allSatisfy { !$0.checked })
                XCTAssertEqual(order == .columns ? expectedIds + [3] : [3] + expectedIds, originals.entries.map(\.id))
                XCTAssertEqual("Keep as a word", originals.restoreLabel(id: 2))
                // A previously stray original remains available for an explicit
                // keep after the group switch, including an all-stray group.
                let corrected = originals.restore(id: 2).change(id: 2, word: "fire").check(id: 2, on: true)
                let back = corrected.restore(id: 1)
                XCTAssertEqual([1, 3], Set(back.entries.map(\.id)))
                XCTAssertFalse(back.entries.first { $0.id == 1 }!.checked)
                XCTAssertTrue(back.entries.first { $0.id == 1 }!.source === expanded)
                XCTAssertFalse(back.reorder(order: order == .rows ? .columns : .rows).entries.first { $0.id == 1 }!.checked)
                let again = back.restore(id: 2).restore(id: 2)
                XCTAssertEqual("fire", again.entries.first { $0.id == 2 }!.word)
                XCTAssertFalse(again.entries.first { $0.id == 2 }!.checked)
                XCTAssertTrue(again.entries.first { $0.id == 2 }!.source === sources[2])
                XCTAssertEqual(["last"], d.remove(id: 1).words)
            }
        }
    }

    func test_singleton_expansion_uses_its_own_verdict_and_clears_checks_on_each_switch() {
        for accepted in [false, true] {
            let original = source("later", accepted: true, stray: true)
            let expanded = Source(corners: Array(repeating: 5, count: 8), ranked: [("later", 0.97)], accepted: accepted,
                                  cropPng: Data([3]), read: "later", expandedFrom: [ExpansionParent(id: 0, stray: false)])
            let d = PhraseDraft(boxes: [original, expanded], columns: [0, 1], rows: [0, 1], order: .columns)
            XCTAssertEqual(1, d.entries.count)
            XCTAssertEqual(accepted, d.entries[0].checked)
            XCTAssertEqual("Use original word", d.restoreLabel(id: 0))
            let restored = d.restore(id: 0)
            XCTAssertEqual(1, restored.entries.count)
            XCTAssertTrue(restored.entries[0].source === original)
            XCTAssertFalse(restored.entries[0].checked)
            let back = restored.check(id: 0, on: true).restore(id: 1)
            XCTAssertEqual(1, back.entries.count)
            XCTAssertTrue(back.entries[0].source === expanded)
            XCTAssertFalse(back.entries[0].checked)
        }
    }

    // Four boxes laid out two by two: columns read a c b d, rows a b c d.
    private func draft() -> PhraseDraft {
        PhraseDraft(boxes: [source("a"), source("b"), source("c"), source("d")],
                    columns: [0, 2, 1, 3], rows: [0, 1, 2, 3], order: .columns)
    }

    func test_the_order_chooses_which_words_follow_which() {
        XCTAssertEqual(["a", "c", "b", "d"], draft().words)
        XCTAssertEqual(["a", "b", "c", "d"], draft().reorder(order: .rows).words)
    }

    func test_changing_a_word_clears_only_its_check() {
        let all = draft()
        XCTAssertTrue(all.allChecked)
        let changed = all.change(id: 2, word: "cat")
        XCTAssertEqual(["a", "cat", "b", "d"], changed.words)
        XCTAssertEqual([true, false, true, true], changed.entries.map(\.checked))
        XCTAssertTrue(changed.entries[1].corrected)
        XCTAssertTrue(changed.check(id: 2, on: true).allChecked)
    }

    func test_an_inserted_word_is_typed_unchecked_and_keeps_its_place_across_orders() {
        let d = draft().checkAll().insert(at: 1, word: "x")
        XCTAssertEqual(["a", "x", "c", "b", "d"], d.words)
        let x = d.entries[1]
        XCTAssertTrue(x.typed)
        XCTAssertFalse(x.checked)
        XCTAssertFalse(d.allChecked)
        // anchored after a: in row order it still follows a
        XCTAssertEqual(["a", "x", "b", "c", "d"], d.reorder(order: .rows).words)
        // at the very start, and between two typed words
        XCTAssertEqual(["s", "a", "x", "c", "b", "d"], d.insert(at: 0, word: "s").words)
        XCTAssertEqual(["a", "x", "y", "c", "b", "d"], d.insert(at: 2, word: "y").words)
        XCTAssertEqual(["a", "c", "b", "d", "e"], draft().insert(at: 4, word: "e").words)
    }

    func test_removing_a_word_drops_its_check_and_typed_words_can_go_too() {
        let d = draft().checkAll().remove(id: 2)
        XCTAssertEqual(["a", "b", "d"], d.words)
        XCTAssertTrue(d.allChecked)
        let typed = d.insert(at: 1, word: "x")
        let id = typed.entries[1].id
        XCTAssertEqual(["a", "b", "d"], typed.remove(id: id).words)
        XCTAssertTrue(typed.remove(id: id).allChecked)
    }

    func test_switching_order_preserves_only_checks_at_unchanged_positions() {
        let d = PhraseDraft(boxes: [source("a"), source("b", accepted: false), source("c"), source("d")],
                            columns: [0, 2, 1, 3], rows: [0, 1, 2, 3], order: .columns)
        let ticked = d.checkAll().reorder(order: .rows)
        XCTAssertEqual([true, false, false, true], ticked.entries.map(\.checked))
        XCTAssertTrue(draft().checkAll().reorder(order: .columns).allChecked)
        // a corrected word stays the person's to tick, through a reorder and back
        let corrected = draft().change(id: 0, word: "cat")
        XCTAssertFalse(corrected.entries[0].checked)
        let rows = corrected.reorder(order: .rows)
        XCTAssertFalse(rows.entries.first { $0.id == 0 }!.checked)
        XCTAssertFalse(rows.entries.first { $0.id == 1 }!.checked)
        XCTAssertFalse(rows.entries.first { $0.id == 2 }!.checked)
        XCTAssertTrue(rows.entries.first { $0.id == 3 }!.checked)
        XCTAssertFalse(rows.reorder(order: .columns).entries.first { $0.id == 0 }!.checked)
        // Returning to the model's spelling does not manufacture confirmation.
        XCTAssertFalse(corrected.change(id: 0, word: "a").reorder(order: .rows).entries.first { $0.id == 0 }!.checked)
    }

    func test_a_stray_starts_left_out_and_comes_back_at_its_place_unchecked() {
        // a stray s between a and c in column order, and c read from the recogniser
        let d = PhraseDraft(
            boxes: [source("a"), source("b"), source("s", stray: true, read: "sea"), source("c", read: "cat")],
            columns: [0, 2, 1, 3], rows: [0, 1, 2, 3], order: .columns
        )
        XCTAssertEqual(["a", "b", "cat"], d.words)
        XCTAssertEqual(["sea"], d.leftOut.map(\.word))
        XCTAssertTrue(d.leftOut[0].source!.stray)
        XCTAssertTrue(d.entries.last!.source!.fromRead)
        XCTAssertFalse(d.entries.first!.source!.fromRead)
        let back = d.checkAll().restore(id: 2)
        XCTAssertEqual(["a", "sea", "b", "cat"], back.words)
        XCTAssertFalse(back.entries[1].checked)
        XCTAssertFalse(back.allChecked)
        XCTAssertTrue(back.leftOut.isEmpty)
        XCTAssertEqual(["a", "b", "sea", "cat"], back.reorder(order: .rows).words)
        // a word the person removed is left out the same way and comes back the same way
        let removed = back.remove(id: 1)
        XCTAssertEqual(["b"], removed.leftOut.map(\.word))
        XCTAssertEqual(["a", "sea", "b", "cat"], removed.restore(id: 1).words)
    }

    func test_a_numbered_page_reads_by_number_and_a_missing_number_is_placed_and_named() {
        // a, b, c, d on the page; the numbers beside them 2, none, 1, 4, so 3 is missing
        let d = PhraseDraft(
            boxes: [source("a", number: 2), source("b"), source("c", number: 1), source("d", number: 4)],
            columns: [0, 1, 2, 3], rows: [0, 1, 2, 3], order: .numbers,
            byNumber: [2, 0, 3, 1],
            numbers: .held(count: 4, missing: [3], outOfPlace: [], unresolved: 0)
        )
        XCTAssertTrue(d.numbered)
        XCTAssertEqual(["c", "a", "d", "b"], d.words)
        // word 3 belongs before d, the first word numbered higher
        XCTAssertEqual([2: 3], d.missingAt())
        XCTAssertEqual("4 words: word 3 was not found", phraseStatus(count: 4, passes: false, numbers: d.numbers))
        let filled = d.insert(at: 2, word: "x")
        XCTAssertEqual(["c", "a", "x", "d", "b"], filled.words)
        // the same words down columns, the numbers still on them, and
        // no place to say where 3 would go
        XCTAssertEqual(["a", "b", "c", "d"], d.reorder(order: .columns).words)
        XCTAssertTrue(d.reorder(order: .columns).missingAt().isEmpty)
        // an unnumbered page has no numbered order to speak of
        XCTAssertFalse(draft().numbered)
        XCTAssertEqual(["a", "c", "b", "d"], draft().reorder(order: .numbers).words)
        XCTAssertTrue(draft().missingAt().isEmpty)
    }

    func test_a_typed_word_fills_the_gap_it_was_offered_and_reopens_it_when_it_goes() {
        // numbers 1..6 and 9..10 on eight boxes: 7 and 8 are missing
        let boxes = (1...10).filter { $0 != 7 && $0 != 8 }.map { source("w\($0)", number: $0) }
        let d = PhraseDraft(
            boxes: boxes, columns: Array(boxes.indices), rows: Array(boxes.indices), order: .numbers,
            byNumber: Array(boxes.indices),
            numbers: .held(count: 10, missing: [7, 8], outOfPlace: [], unresolved: 0)
        )
        XCTAssertEqual([6: 7], d.missingAt())
        XCTAssertEqual("8 words: words 7 and 8 were not found", phraseStatus(count: 8, passes: false, numbers: d.numbers))
        // filling 7 at its place: the offer moves on to 8, after the new word
        let seven = d.insert(at: 6, word: "seven", number: 7)
        XCTAssertEqual(7, seven.entries[6].number)
        XCTAssertEqual([7: 8], seven.missingAt())
        XCTAssertEqual("9 words: word 8 was not found", phraseStatus(count: 9, passes: false, numbers: seven.numbers))
        let eight = seven.insert(at: 7, word: "eight", number: 8)
        XCTAssertTrue(eight.missingAt().isEmpty)
        XCTAssertEqual([7, 8], eight.entries[6..<8].map(\.number))
        XCTAssertEqual(Numbers.held(count: 10, missing: [], outOfPlace: [], unresolved: 0), eight.numbers)
        XCTAssertEqual("10 words: this worksheet holds a 12-word phrase",
                       phraseStatus(count: 10, passes: false, numbers: eight.numbers))
        // the number stays through a correction and either order, and the
        // scan's own reading is kept apart
        XCTAssertEqual(7, eight.change(id: seven.entries[6].id, word: "heaven").entries[6].number)
        XCTAssertEqual([7, 8], eight.reorder(order: .columns).entries[6..<8].map(\.number))
        guard case let .held(_, missing, _, _) = eight.scanNumbers else { return XCTFail("not held") }
        XCTAssertEqual([7, 8], missing)
        // removing the word reopens its gap, and an ordinary insertion fills none
        let gone = eight.remove(id: seven.entries[6].id)
        XCTAssertEqual([6: 7], gone.missingAt())
        let plain = gone.insert(at: 6, word: "plain")
        XCTAssertNil(plain.entries[6].number)
        XCTAssertEqual([6: 7], plain.missingAt())
    }

    func test_the_numbering_note_says_what_the_page_s_numbers_left_open() {
        XCTAssertNil(numberingNote(numbers: .none))
        XCTAssertNil(numberingNote(numbers: .held(count: 12, missing: [], outOfPlace: [], unresolved: 0)))
        XCTAssertEqual(
            "Number 5 is not where the page puts it: check the order.",
            numberingNote(numbers: .held(count: 12, missing: [], outOfPlace: [5], unresolved: 0))
        )
        XCTAssertEqual(
            "Numbers 5, 6 are not where the page puts them: check the order. A number beside 1 word could not be read.",
            numberingNote(numbers: .held(count: 12, missing: [], outOfPlace: [5, 6], unresolved: 1))
        )
        XCTAssertEqual(
            "The numbers on the page contradict each other, so the words are in the order they sit on the page.",
            numberingNote(numbers: .inconsistent(detail: "two boxes are numbered 4"))
        )
        XCTAssertEqual("11 words: words 4 and 7 were not found",
                       phraseStatus(count: 11, passes: false,
                                    numbers: .held(count: 12, missing: [4, 7], outOfPlace: [], unresolved: 0)))
        XCTAssertEqual("12 words · checksum passes",
                       phraseStatus(count: 12, passes: true,
                                    numbers: .held(count: 12, missing: [], outOfPlace: [], unresolved: 0)))
    }

    func test_supported_order_can_start_confident_but_reordering_never_regrants_ticks() {
        let d = PhraseDraft(
            boxes: [source("a"), source("b", accepted: false), source("c"), source("s", stray: true)],
            columns: [0, 2, 1, 3], rows: [0, 1, 2, 3], order: .columns
        )
        XCTAssertEqual([true, true, false], d.entries.map(\.checked))
        XCTAssertFalse(d.allChecked)
        // Edits take a tick back; reordered positions require fresh checks.
        XCTAssertEqual([false, true, false], d.change(id: 0, word: "cat").entries.map(\.checked))
        let all = d.check(id: 1, on: true)
        XCTAssertTrue(all.allChecked)
        XCTAssertEqual([true, false, false], all.reorder(order: .rows).entries.map(\.checked))
        XCTAssertEqual([false, false, false], all.check(id: 0, on: false).reorder(order: .rows).entries.map(\.checked))
        // a stray put back and a typed word are the person's to tick
        XCTAssertFalse(all.restore(id: 3).entries.first { $0.id == 3 }!.checked)
        XCTAssertFalse(all.insert(at: 1, word: "x").entries[1].checked)
        XCTAssertEqual("12 words · checksum passes · 9 of 12 ticked", phraseStatus(count: 12, passes: true, ticked: 9))
        XCTAssertEqual("12 words · checksum fails: review the words", phraseStatus(count: 12, passes: false, ticked: 9))
    }

    func test_the_status_line_names_the_count_and_the_checksum() {
        XCTAssertEqual("12 words · checksum passes", phraseStatus(count: 12, passes: true))
        XCTAssertEqual("12 words · checksum fails: review the words", phraseStatus(count: 12, passes: false))
        XCTAssertEqual("11 words: a word is missing", phraseStatus(count: 11, passes: false))
        XCTAssertEqual("13 words: one word too many", phraseStatus(count: 13, passes: false))
        XCTAssertEqual("24 words: this worksheet holds a 12-word phrase", phraseStatus(count: 24, passes: true))
        XCTAssertEqual("0 words: this worksheet holds a 12-word phrase", phraseStatus(count: 0, passes: false))
    }
}
