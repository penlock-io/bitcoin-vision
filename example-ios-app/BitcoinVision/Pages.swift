import SwiftUI

/** A short message at the foot of a page, as Material's snackbar shows it. */
@Observable @MainActor
final class SnackbarState {
    private(set) var message: String?
    private var shown = 0

    func show(_ text: String) {
        shown += 1
        let mine = shown
        withAnimation(Motion.state) { message = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if shown == mine { withAnimation(Motion.state) { message = nil } }
        }
    }

    func dismiss() {
        withAnimation(Motion.state) { message = nil }
    }
}

private struct SnackbarHost: View {
    let state: SnackbarState?

    var body: some View {
        if let text = state?.message {
            Text(text)
                .font(.bodyMedium)
                .foregroundStyle(Palette.surface)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.onSurface))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { state?.dismiss() }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/** The back control the app's pages share, so every page leaves the same way. */
private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44, alignment: .leading)
        }
        .accessibilityLabel("Back")
        .accessibilityIdentifier("back")
    }
}

/**
 * Guided work: a scrollable body above a stable action area pinned to the
 * bottom safe area. The Android app's TaskPage.
 */
struct TaskPage<Bar: View, Actions: View, Content: View>: View {
    let title: String
    let onBack: () -> Void
    var snackbar: SnackbarState? = nil
    @ViewBuilder var bar: () -> Bar
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            VStack(spacing: 4) { actions() }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .overlay(alignment: .bottom) { SnackbarHost(state: snackbar) }
        .background(Palette.surface.ignoresSafeArea())
        .foregroundStyle(Palette.onSurface)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { BackButton(action: onBack) }
            ToolbarItemGroup(placement: .topBarTrailing) { bar() }
        }
    }
}

extension TaskPage where Bar == EmptyView {
    init(
        title: String,
        onBack: @escaping () -> Void,
        snackbar: SnackbarState? = nil,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, onBack: onBack, snackbar: snackbar, bar: { EmptyView() }, actions: actions, content: content)
    }
}

/**
 * The wallet's small hierarchical pages: a title, an optional back control,
 * and a scrolling column. The Android app's WalletPage.
 */
struct WalletPage<Actions: View, Floating: View, Content: View>: View {
    let title: String
    var onBack: (() -> Void)? = nil
    var titleTag: String = "page-title"
    var snackbar: SnackbarState? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var floatingAction: () -> Floating
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomTrailing) {
            floatingAction().padding(16)
        }
        .overlay(alignment: .bottom) { SnackbarHost(state: snackbar) }
        .background(Palette.surface.ignoresSafeArea())
        .foregroundStyle(Palette.onSurface)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) { BackButton(action: onBack) }
            }
            ToolbarItemGroup(placement: .topBarTrailing) { actions() }
        }
        .accessibilityIdentifier(titleTag)
    }
}

extension WalletPage where Floating == EmptyView {
    init(
        title: String,
        onBack: (() -> Void)? = nil,
        titleTag: String = "page-title",
        snackbar: SnackbarState? = nil,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, onBack: onBack, titleTag: titleTag, snackbar: snackbar,
                  actions: actions, floatingAction: { EmptyView() }, content: content)
    }
}

extension WalletPage where Floating == EmptyView, Actions == EmptyView {
    init(
        title: String,
        onBack: (() -> Void)? = nil,
        titleTag: String = "page-title",
        snackbar: SnackbarState? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, onBack: onBack, titleTag: titleTag, snackbar: snackbar,
                  actions: { EmptyView() }, floatingAction: { EmptyView() }, content: content)
    }
}

/** A quiet row: the title is the whole message; a trailing label may carry a fact. */
struct WalletLink<Trailing: View>: View {
    let title: String
    let tag: String
    let onClick: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: onClick) {
            HStack {
                Text(title).font(.bodyLarge).foregroundStyle(Palette.onSurface)
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(tag)
    }
}

extension WalletLink where Trailing == AnyView {
    init(title: String, tag: String, onClick: @escaping () -> Void) {
        self.init(title: title, tag: tag, onClick: onClick) {
            AnyView(Image(systemName: "chevron.right").foregroundStyle(Palette.onSurfaceVariant))
        }
    }
}
