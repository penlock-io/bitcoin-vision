/** The second share needs a valid pair check and explicit paper confirmation for any non-exact row. */
func shareUseAllowed(
    firstShareHeld: Bool,
    pair: CombinedStripReview?,
    paperChecked: Bool
) -> Bool {
    guard firstShareHeld else { return true }
    guard let pair, pair.rows.count == 12 else { return false }
    return pair.rows.allSatisfy { $0.status == .exact } || paperChecked
}
