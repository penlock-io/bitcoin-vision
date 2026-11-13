import SwiftUI

/**
 * The app's navigation: the Android app's App.kt, route for route. Every
 * flow-level decision (where a scan returns to, what a finished scan
 * does with its words) lives here, and the screens only report events.
 */
struct AppRoot: View {
    @Binding var incoming: Data?

    @State private var nav = Navigator()
    @State private var wallets = WalletsViewModel()
    @State private var sheet = SheetViewModel()
    @State private var strips = StripsViewModel()
    @State private var creation = NewSeedViewModel()

    var body: some View {
        NavigationStack(path: $nav.path) {
            WalletsScreen(
                wallets: wallets,
                onAdd: { nav.navigate(.add) },
                onOpen: { id in nav.navigate(.wallet(id: id)) }
            )
            .navigationDestination(for: Route.self) { route in
                destination(route)
            }
        }
        .tint(Palette.primary)
        // A PSBT shared to the app, from wherever the person was.
        .onChange(of: incoming, initial: true) { _, bytes in
            guard let bytes else { return }
            incoming = nil
            creation.cancel()
            wallets.receive(bytes)
            reviewIncoming()
        }
    }

    // MARK: Flow decisions

    private static let signingRoutes: [Route] = [.signPick, .signScan, .signReview, .signSigned]

    /**
     * Replace the entire signing visit, including nested key loading, while
     * keeping the original caller beneath it rather than obsolete review pages.
     */
    private func reviewIncoming() {
        let first = nav.stack.first { Self.signingRoutes.contains($0) }
        if nav.stack.contains(where: { $0.task == "sign" }) {
            sheet.forget()
            strips.cancel()
        }
        nav.navigate(.signReview, popUpTo: first, inclusive: true, singleTop: true)
    }

    /** The review sits on top of wherever the PSBT found the person: done with it, they are back there. */
    private func leaveSigning() {
        wallets.dismissSigning()
        nav.popBackStack()
    }

    private func open(_ id: String) {
        // Creation may immediately open the write-down page before the overview appears.
        wallets.leaveSigningUnless(id)
        nav.navigate(.wallet(id: id), popUpTo: .wallets)
    }

    /**
     * The wallet page opens the camera directly; other callers go through the
     * method chooser. Leaving a scan returns to whichever of the two sent it.
     */
    private func viaChooser(_ purpose: String, _ task: String) -> Bool {
        nav.stack.contains(.load(id: purpose, task: task))
    }

    @discardableResult
    private func leave(_ purpose: String, _ task: String) -> Bool {
        if purpose == Purpose.add {
            return nav.popBackStack(.add)
        } else if viaChooser(purpose, task) {
            return nav.popBackStack(.load(id: purpose, task: task))
        } else {
            return nav.popBackStack(.wallet(id: purpose))
        }
    }

    /** Words from a scan, taken as the route meant them. */
    private func accept(_ purpose: String, _ task: String, _ words: [String], _ source: KeySource) {
        sheet.forget()
        if purpose == Purpose.add {
            if let id = wallets.take(words: words, source: source) {
                open(id)
            } else {
                leave(purpose, task)
            }
        } else {
            let loaded = wallets.loadInto(id: purpose, words: words, source: source)
            let chooser = viaChooser(purpose, task)
            let returned = leave(purpose, task)
            if loaded && returned {
                // Pop the method chooser to its caller; a pending review stays pending.
                if chooser { nav.popBackStack() }
                if task == "backup" && wallets.makeShares(id: purpose) { nav.navigate(.backupShares) }
            }
        }
    }

    private func backToBackedUp() {
        let id = wallets.backup?.walletId
        wallets.endBackup()
        if let id {
            nav.popBackStack(.wallet(id: id))
        } else {
            nav.popBackStack(.wallets)
        }
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .wallets:
            WalletsScreen(
                wallets: wallets,
                onAdd: { nav.navigate(.add) },
                onOpen: { id in nav.navigate(.wallet(id: id)) }
            )
        case .add:
            AddWalletScreen(
                onNewKey: { if creation.start() { nav.navigate(.newBackup) } },
                onScanPhrase: {
                    sheet.start()
                    nav.navigate(.sheetScan(purpose: Purpose.add, task: "wallet"))
                },
                onScanStrips: {
                    strips.start()
                    nav.navigate(.stripsScan(purpose: Purpose.add, task: "wallet"))
                },
                onBack: { nav.popBackStack() }
            )
        case .wallet(let id):
            WalletScreen(
                wallets: wallets,
                id: id,
                onBack: { nav.popBackStack(.wallets) },
                onKeys: { nav.navigate(.keys(id: id)) },
                onScan: {
                    sheet.start()
                    nav.navigate(.sheetScan(purpose: id, task: "wallet"))
                },
                onStrips: {
                    strips.start()
                    nav.navigate(.stripsScan(purpose: id, task: "wallet"))
                },
                onConnect: { nav.navigate(.connect(id: id)) },
                onBackUp: {
                    if wallets.key(id: id) == nil {
                        nav.navigate(.load(id: id, task: "backup"))
                    } else if wallets.makeShares(id: id) {
                        nav.navigate(.backupShares)
                    }
                },
                onSign: { nav.navigate(.signPick) },
                onReview: { nav.navigate(.signReview) }
            )
        case .newBackup:
            NewSeedScreen(
                model: creation,
                onCancel: {
                    creation.cancel()
                    nav.popBackStack(.add)
                },
                onComplete: {
                    if let id = wallets.completeNew(creation: creation) { open(id) }
                }
            )
        case .connect(let id):
            ConnectWalletScreen(wallets: wallets, id: id, onBack: { nav.popBackStack() })
        case .keys(let id):
            KeyControlsScreen(
                wallets: wallets, id: id,
                onBack: { nav.popBackStack() },
                onLoadKey: { nav.navigate(.load(id: id, task: "keys")) }
            )
        case .load(let id, let task):
            LoadKeyScreen(
                wallets: wallets, id: id, task: task,
                onBack: { nav.popBackStack() },
                onScanPhrase: {
                    sheet.start()
                    nav.navigate(.sheetScan(purpose: id, task: task))
                },
                onScanStrips: {
                    strips.start()
                    nav.navigate(.stripsScan(purpose: id, task: task))
                }
            )
        case .signPick:
            SignPickScreen(
                wallets: wallets,
                onScanQr: { nav.navigate(.signScan) },
                onReviewed: { reviewIncoming() },
                onBack: { nav.popBackStack() }
            )
        case .signScan:
            QrScanScreen(
                title: "Scan the transaction",
                onPsbt: { bytes in
                    wallets.receive(bytes)
                    reviewIncoming()
                },
                onExit: { nav.popBackStack() }
            )
        case .signReview:
            ReviewPsbtScreen(
                wallets: wallets,
                onSigned: { nav.navigate(.signSigned, popUpTo: .signReview, inclusive: true) },
                onLoadKey: { id in nav.navigate(.load(id: id, task: "sign")) },
                onChooseAnother: {
                    wallets.dismissSigning()
                    nav.navigate(.signPick, popUpTo: .signReview, inclusive: true)
                },
                onBack: { nav.popBackStack() },
                onDone: { leaveSigning() }
            )
        case .signSigned:
            SignedScreen(wallets: wallets, onDone: { leaveSigning() })
        case .sheetScan(let purpose, let task):
            SheetScanScreen(
                viewModel: sheet,
                onReviewed: { nav.navigate(.sheetReview(purpose: purpose, task: task)) },
                onExit: {
                    sheet.forget()
                    leave(purpose, task)
                }
            )
        case .sheetReview(let purpose, let task):
            ReviewScreen(
                viewModel: sheet,
                action: purpose == Purpose.add ? "Add wallet" : "Load key",
                onAccept: {
                    if let words = sheet.confirmed() {
                        accept(purpose, task, words, .writtenPhrase)
                    }
                },
                onBack: {
                    sheet.rescan()
                    nav.popBackStack(.sheetScan(purpose: purpose, task: task))
                }
            )
        case .stripsScan(let purpose, let task):
            StripScanScreen(
                viewModel: strips,
                onRecovered: {
                    let scan = strips.scan
                    strips.finish()
                    guard case let .recovered(words, first, second) = scan else {
                        if purpose == Purpose.check {
                            nav.popBackStack(.backupCheck)
                        } else {
                            leave(purpose, task)
                        }
                        return
                    }
                    if purpose == Purpose.check {
                        wallets.checkStrips(read: words)
                        nav.navigate(.backupChecked, popUpTo: .backupCheck)
                    } else {
                        accept(purpose, task, words, .strips(first: first, second: second))
                    }
                },
                onExit: {
                    strips.cancel()
                    if purpose == Purpose.check {
                        nav.popBackStack(.backupCheck)
                    } else {
                        leave(purpose, task)
                    }
                }
            )
        case .backupShares:
            SharesScreen(
                wallets: wallets,
                onCheck: { nav.navigate(.backupCheck) },
                onDone: { backToBackedUp() }
            )
        case .backupCheck:
            if wallets.backup == nil {
                EndedBackupScreen(onDone: { backToBackedUp() })
            } else {
                BackupCheckScreen(
                    onScan: {
                        strips.start()
                        nav.navigate(.stripsScan(purpose: Purpose.check, task: "wallet"))
                    },
                    onBack: { nav.popBackStack(.backupShares) }
                )
            }
        case .backupChecked:
            CheckedScreen(
                wallets: wallets,
                onAgain: { nav.popBackStack(.backupShares) },
                onRetry: {
                    strips.start()
                    nav.navigate(.stripsScan(purpose: Purpose.check, task: "wallet"), popUpTo: .backupCheck)
                },
                onDone: { backToBackedUp() }
            )
        }
    }
}
