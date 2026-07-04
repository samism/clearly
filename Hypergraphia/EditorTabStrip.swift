import SwiftUI
import AppKit
import Combine
import HypergraphiaCore

/// Replaces the native window tab bar under the titlebar-less glass chrome.
/// The native bar spans the whole window — cutting across the floating
/// sidebar — so it stays hidden (`hideNativeTabBar`) and this strip renders
/// the same `NSWindowTabGroup` nested at the top of the editor column
/// instead. Tab grouping, switching, and closing all still go through the
/// native tab machinery.
@MainActor
final class EditorTabModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let isSelected: Bool
        let window: NSWindow

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.isSelected == rhs.isSelected
        }
    }

    @Published private(set) var tabs: [Tab] = []
    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var titleCancellables: [AnyCancellable] = []

    /// Called from the window-resolving representable; may fire on every
    /// SwiftUI update, so everything in here must be idempotent and cheap.
    func adopt(_ window: NSWindow) {
        if self.window !== window {
            self.window = window
        }
        if observers.isEmpty {
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.willCloseNotification
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    // willClose fires while the closing window is still in
                    // the tab group — recompute on the next runloop pass.
                    DispatchQueue.main.async {
                        self?.refresh()
                    }
                })
            }
        }
        refresh()
    }

    func refresh() {
        if #available(macOS 26.0, *) {
            hideNativeTabBar(in: window)
        }
        guard let window else {
            if !tabs.isEmpty {
                tabs = []
            }
            return
        }
        // The strip is always visible: a window outside any tab group (or
        // alone in one) still shows itself as a single tab.
        let group = window.tabGroup
        let windows = (group?.windows.count ?? 0) > 1 ? (group?.windows ?? []) : [window]
        let newTabs = windows.map { tab in
            Tab(
                id: ObjectIdentifier(tab),
                title: tab.title.isEmpty ? "Untitled" : tab.title,
                isSelected: (group?.selectedWindow ?? window) === tab,
                window: tab
            )
        }
        // Only publish real changes: adopt()/refresh() run inside SwiftUI
        // update passes, and an unconditional @Published write would spin an
        // endless update cycle.
        guard newTabs != tabs else { return }
        tabs = newTabs
        titleCancellables = windows.map { tab in
            tab.publisher(for: \.title).dropFirst().sink { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func select(_ tab: Tab) {
        window?.tabGroup?.selectedWindow = tab.window
        tab.window.makeKeyAndOrderFront(nil)
        refresh()
    }

    func close(_ tab: Tab) {
        // The last tab doesn't take the window with it: a fresh untitled
        // tab replaces it in the same frame.
        if tabs.count == 1, tab.window === window {
            replaceOnlyTabWithUntitled(in: tab.window)
        } else {
            tab.window.performClose(nil)
        }
    }
}

@available(macOS 26.0, *)
struct EditorTabStrip: View {
    @ObservedObject var model: EditorTabModel
    /// Extra leading space so tabs clear the floating traffic lights and
    /// sidebar toggle when the sidebar is hidden and the strip starts at
    /// the window's left edge.
    var leadingInset: CGFloat = 0

    var body: some View {
        // Tabs float as Liquid Glass capsules over the content — no opaque
        // band, so mid-scroll text passes visibly beneath them, Safari-
        // style. The container keeps the capsules in one glass family. A
        // lone tab shows no capsule at all — nothing to switch between —
        // leaving the band as a bare window-drag handle. (The + button is
        // not part of the strip: it lives in its own always-visible
        // overlay, pinned at the window's trailing edge.)
        GlassEffectContainer {
            HStack(spacing: 8) {
                if model.tabs.count > 1 {
                    ForEach(model.tabs) { tab in
                        TabItem(tab: tab) {
                            model.select(tab)
                        } close: {
                            model.close(tab)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
        .padding(.leading, 8 + leadingInset)
        // Trailing room keeps stretched tabs clear of the + button pinned
        // at the trailing edge (and of the scroller / rounded corner).
        .padding(.trailing, 54)
        .padding(.vertical, 5)
        // The strip sits in the old titlebar band, so its empty areas act
        // as the window-drag handle.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }
}

@available(macOS 26.0, *)
private struct TabItem: View {
    let tab: EditorTabModel.Tab
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Text(tab.title)
                .font(.system(size: 12, weight: tab.isSelected ? .medium : .regular))
                .foregroundStyle(tab.isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 28)

            HStack {
                if showsClose {
                    // Deliberately NOT a Button: the capsule underneath
                    // carries its own select `.onTapGesture`, and on macOS a
                    // nested Button loses that arbitration — the ✕ was
                    // nearly unclickable. A child tap gesture wins over the
                    // parent's (deepest view first), and the hit target is a
                    // full-height leading zone, not just the 16pt glyph box.
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.hoverColor(inDark: colorScheme == .dark))
                        )
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)
                        .help("Close tab")
                        .accessibilityLabel("Close \(tab.title)")
                        .accessibilityAddTraits(.isButton)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        // Select/hover live INSIDE the glass boundary, in the same event
        // world as the ✕ above. Attached outside `.glassEffect`, they sat
        // behind the effect's AppKit-backed view and only fired reliably in
        // the sliver the glass didn't claim — tabs felt unclickable.
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: select)
        .onHover { hovering in
            // Explicit cursor control (covers the ✕ too — it sits inside
            // the capsule): pointer styles lose to the web view beneath.
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            withAnimation(Theme.Motion.hover) {
                isHovered = hovering
            }
        }
        // The selected tab carries the accent as a glass tint (the same
        // treatment as the bottom toolbar's active outline toggle);
        // unselected tabs are plain interactive glass.
        .glassEffect(
            tab.isSelected
                ? .regular.tint(Theme.accentColorSwiftUI.opacity(0.2)).interactive()
                : .regular.interactive(),
            in: .capsule
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title) tab")
        .accessibilityAddTraits(tab.isSelected ? .isSelected : [])
    }

    /// The ✕ is always present on the selected tab (Safari-style) and
    /// hover-revealed on the others — closing must not depend on catching
    /// a hover animation first.
    private var showsClose: Bool {
        tab.isSelected || isHovered
    }
}
