import SwiftUI

/**
 * The app's destinations, as the Android app's NavHost routes name them.
 * The scan flows serve three purposes, carried in their routes: a new wallet
 * (`Purpose.add`), the key of a saved wallet (its id), or a backup check.
 */
enum Route: Hashable {
    case wallets
    case add
    case wallet(id: String)
    case newBackup
    case connect(id: String)
    case keys(id: String)
    case load(id: String, task: String)
    case signPick
    case signScan
    case signReview
    case signSigned
    case sheetScan(purpose: String, task: String)
    case sheetReview(purpose: String, task: String)
    case stripsScan(purpose: String, task: String)
    case backupShares
    case backupCheck
    case backupChecked

    /** The route's task argument, where it has one. */
    var task: String? {
        switch self {
        case .load(_, let task), .sheetScan(_, let task), .sheetReview(_, let task), .stripsScan(_, let task):
            return task
        default:
            return nil
        }
    }
}

enum Purpose {
    static let add = "add"
    static let check = "check"
}

/**
 * A back stack with the operations the Android app's NavController offers:
 * the root (`wallets`) is fixed, everything above it is `path`.
 */
@Observable @MainActor
final class Navigator {
    var path: [Route] = []

    /** The whole stack, root first. */
    var stack: [Route] { [.wallets] + path }

    var current: Route { path.last ?? .wallets }

    func navigate(_ route: Route, popUpTo: Route? = nil, inclusive: Bool = false, singleTop: Bool = false) {
        if let popUpTo {
            truncate(to: popUpTo, inclusive: inclusive)
        }
        if singleTop && current == route { return }
        path.append(route)
    }

    /** Pops the top page; false when only the root is left. */
    @discardableResult
    func popBackStack() -> Bool {
        guard !path.isEmpty else { return false }
        path.removeLast()
        return true
    }

    /**
     * Pops back to the most recent `route`, keeping it unless `inclusive`.
     * True when the route was on the stack and at least one page was popped,
     * as NavController.popBackStack(route, inclusive) answers.
     */
    @discardableResult
    func popBackStack(_ route: Route, inclusive: Bool = false) -> Bool {
        let before = path.count
        guard truncate(to: route, inclusive: inclusive) else { return false }
        return path.count < before
    }

    @discardableResult
    private func truncate(to route: Route, inclusive: Bool) -> Bool {
        let all = stack
        guard let index = all.lastIndex(of: route) else { return false }
        // Index 0 is the root, which is never popped.
        let keep = max(inclusive ? index : index + 1, 1)
        path = Array(all[1..<keep])
        return true
    }
}
