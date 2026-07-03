import SwiftUI
import AppKit
import HypergraphiaCore

/// Per-document scene root: hosts the editor / preview, find bar, jump-to-line
/// bar, outline panel, and the floating bottom toolbar (mode picker / counts /
/// copy / outline). One instance per `DocumentGroup` window.
struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @State private var viewMode: ViewMode
    /// Shared across all windows/tabs (and relaunches): tab switches must
    /// not appear to flip the sidebar between files and outline.
    @AppStorage("sidebarMode") private var sidebarMode: SidebarMode = .folder
    @StateObject private var outlineState = OutlineState()
    @StateObject private var folderState = FolderState()
    @StateObject private var findState = FindState()
    @StateObject private var jumpToLineState = JumpToLineState()
    @StateObject private var statusBarState = StatusBarState()
    @StateObject private var tabModel = EditorTabModel()

    @AppStorage("editorFontSize") private var fontSize: Double = 12
    @AppStorage("previewFontFamily") private var previewFontFamily: String = "sanFrancisco"
    @AppStorage("contentWidth") private var contentWidth: String = "off"
    @AppStorage("alwaysShowBottomToolbar") private var alwaysShowBottomToolbar: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringBottom: Bool = false

    /// Stable per-window key for ScrollBridge / SelectionBridge. Re-keyed on
    /// document URL change so two windows on different files don't collide.
    @State private var positionSyncID: String = UUID().uuidString

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        self._document = document
        self.fileURL = fileURL
        // Never land a blank document in Preview — there'd be nothing to see
        // and no obvious way to edit. (Live is fine: it shows a click-to-
        // start-writing affordance.)
        let raw = UserDefaults.standard.string(forKey: "defaultViewMode") ?? "live"
        let preferred = ViewMode(rawValue: raw) ?? .live
        let isBlank = document.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self._viewMode = State(initialValue: (preferred == .preview && isBlank) ? .edit : preferred)
    }

    private var shouldShowBottomToolbar: Bool {
        alwaysShowBottomToolbar || isHoveringBottom
    }

    private var contentWidthEm: CGFloat? {
        switch contentWidth {
        case "narrow": return 50
        case "medium": return 65
        case "wide": return 80
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { proxy in
            mainLayout(topInset: proxy.safeAreaInsets.top)
        }
        .frame(minWidth: 600, minHeight: 360)
        .background(WindowTitleSetter(fileURL: fileURL, newFile: { window in
            newFile(tabbingInto: window)
        }, onWindow: { window in
            tabModel.adopt(window)
        }))
        .focusedSceneValue(\.findState, findState)
        .focusedSceneValue(\.outlineState, outlineState)
        .focusedSceneValue(\.viewMode, $viewMode)
        .focusedSceneValue(\.exportPDFAction) { exportPDF() }
        .focusedSceneValue(\.printDocumentAction) { printDocument() }
        .focusedSceneValue(\.openFolderAction) { openFolder() }
        .focusedSceneValue(\.newFileAction) { newFile() }
        .onAppear {
            outlineState.parseHeadings(from: document.text)
            statusBarState.updateText(document.text)
            // Window opened from another window's folder sidebar: orient this
            // window to the same folder.
            if let folder = FolderHandoff.claim(for: fileURL) {
                folderState.open(folder: folder)
                sidebarMode = .folder
                outlineState.isVisible = true
            } else {
                orientSidebarToDocumentFolder()
            }
        }
        .onChange(of: document.text) { _, newText in
            outlineState.parseHeadings(from: newText)
            statusBarState.updateText(newText)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Sidebar visibility persists globally ("outlineVisible"), but
            // each tab is its own window whose OutlineState snapshotted the
            // default at init. Without reconciling on key changes, switching
            // tabs flips between stale snapshots and the sidebar appears to
            // toggle on its own.
            let stored = UserDefaults.standard.bool(forKey: "outlineVisible")
            if outlineState.isVisible != stored {
                outlineState.isVisible = stored
            }
        }
        .onChange(of: fileURL) { _, _ in
            // Re-key bridges when the document is saved/renamed so a new
            // file's scroll position doesn't inherit the old fraction.
            positionSyncID = UUID().uuidString
            orientSidebarToDocumentFolder()
        }
        .watchExternalChanges(fileURL: fileURL, text: $document.text) { url in
            // Sync SwiftUI's underlying NSDocument's fileModificationDate to
            // the new on-disk mtime — without this, the next autosave detects
            // a conflict and shows "could not be autosaved" dialog. We
            // deliberately do NOT try to suppress the title's "Edited"
            // decoration: SwiftUI tracks its own FileDocument-vs-disk diff
            // for that, and the indicator is a useful "doc changed under you"
            // signal anyway.
            let target = url.standardizedFileURL
            guard let doc = NSDocumentController.shared.documents.first(where: { $0.fileURL?.standardizedFileURL == target }) else { return }
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                doc.fileModificationDate = mtime
            }
        }
    }

    /// Window content. `topInset` is the height of the (transparent) titlebar
    /// region — the traffic-light strip, plus the native tab bar when tabs are
    /// showing. The sidebar extends up under it; the editor column stays
    /// below it.
    @ViewBuilder
    private func mainLayout(topInset rawTopInset: CGFloat) -> some View {
        // When our own tab strip is handling tabs, the hidden native tab bar
        // may still reserve titlebar height in the safe area — cap the inset
        // at the plain traffic-light strip so the content reclaims that space.
        let topInset = tabModel.tabs.isEmpty ? rawTopInset : min(rawTopInset, 28)
        HStack(spacing: 0) {
            if outlineState.isVisible {
                sidebar(topInset: topInset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                if #available(macOS 26.0, *), tabsShowing {
                    // Tabs live in the traffic-light band (Safari-style);
                    // the strip's divider lines up with the sidebar's
                    // top-strip separator. With the sidebar hidden, the
                    // leading inset keeps tabs clear of the floating
                    // traffic lights and toggle.
                    EditorTabStrip(
                        model: tabModel,
                        leadingInset: outlineState.isVisible ? 0 : 122
                    ) {
                        newFile(tabbingInto: tabModel.window)
                    }
                    .padding(.top, 7)
                    .padding(.bottom, 7)
                    Divider()
                }
                if findState.isVisible {
                    FindBarView(findState: findState)
                    Divider()
                }
                if jumpToLineState.isVisible {
                    JumpToLineBar(state: jumpToLineState)
                    Divider()
                }

                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        bottomToolbarOverlay
                    }
            }
            // The traffic-light band only needs reserving when it actually
            // floats over the editor column: sidebar hidden and no tab strip.
            // With the sidebar open the lights sit over the panel, so the
            // editor content rises to the window top.
            .padding(.top, (tabsShowing || outlineState.isVisible) ? 0 : topInset)
        }
        // Match the editor background so the gutters around the floating
        // glass sidebar read as one continuous surface, not window chrome.
        .background(Theme.backgroundColorSwiftUI)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            if #available(macOS 26.0, *), topInset > 0, !tabsShowing, !outlineState.isVisible {
                // The titlebar is hidden; this strip keeps the top of the
                // window draggable when no tab strip occupies it and the
                // sidebar (whose top strip has its own drag handle) is
                // hidden. Content-blocking matters: when the editor rises to
                // the window top, this overlay must not sit over it. Overlay
                // content gets the container safe area re-applied, so it
                // must ignore it again to reach the true window top.
                Color.clear
                    .frame(height: topInset)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .overlay(alignment: .topLeading) {
            if #available(macOS 26.0, *) {
                sidebarToggle
                    .padding(.leading, 90)
                    .padding(.top, 13)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        // Fast slide for the sidebar; the editor column, tab-strip inset,
        // and button row glide along with it. Scoped to visibility so no
        // other layout change picks up the animation.
        .animation(
            reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9),
            value: outlineState.isVisible
        )
    }

    /// Whether the custom editor tab strip is occupying the top band.
    private var tabsShowing: Bool {
        if #available(macOS 26.0, *) {
            return !tabModel.tabs.isEmpty
        }
        return false
    }

    /// Claude-desktop-style toggle that lives next to the traffic lights —
    /// inside the glass sidebar when it's open, floating over the editor
    /// strip when it's closed.
    @available(macOS 26.0, *)
    private var sidebarToggle: some View {
        Button {
            outlineState.isVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(outlineState.isVisible ? "Hide sidebar" : "Show sidebar")
        .accessibilityLabel(outlineState.isVisible ? "Hide sidebar" : "Show sidebar")
    }

    private var bottomToolbarOverlay: some View {
        ZStack(alignment: .bottom) {
            BottomHoverTracker { hovering in
                withAnimation(.easeInOut(duration: 0.18)) {
                    isHoveringBottom = hovering
                }
            }
            .frame(height: 96)

            if shouldShowBottomToolbar {
                LinearGradient(
                    stops: [
                        .init(color: Theme.backgroundColorSwiftUI.opacity(0), location: 0),
                        .init(color: Theme.backgroundColorSwiftUI.opacity(0.7), location: 0.55),
                        .init(color: Theme.backgroundColorSwiftUI, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 96)
                .allowsHitTesting(false)
                .transition(.opacity)

                BottomToolbar(
                    viewMode: $viewMode,
                    statusBarState: statusBarState,
                    outlineState: outlineState,
                    fileURL: fileURL,
                    documentText: { document.text }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// Left sidebar. On macOS 26+ it floats as an inset Liquid Glass panel —
    /// same rounded-glass chrome Finder and Xcode use for their sidebars —
    /// with a faint blue cast, hosting the traffic lights in its top strip.
    /// Earlier systems keep the flat full-height panel.
    @ViewBuilder
    private func sidebar(topInset: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            SidebarView(
                mode: $sidebarMode,
                outlineState: outlineState,
                folderState: folderState,
                isEditorVisible: viewMode == .edit,
                fileURL: fileURL,
                // Top strip tall enough for the traffic lights + overlay
                // buttons; its separator sits at 48pt from the window top,
                // level with the tab strip's divider.
                chromeTopPadding: max(40, topInset + 12)
            )
            .frame(width: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .glassEffect(
                // systemBlue resolves dynamically for light/dark; the low
                // opacity keeps it a hue the glass picks up, not a fill.
                .regular.tint(Color(nsColor: .systemBlue).opacity(colorScheme == .dark ? 0.15 : 0.1)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
        } else {
            SidebarView(
                mode: $sidebarMode,
                outlineState: outlineState,
                folderState: folderState,
                isEditorVisible: viewMode == .edit,
                fileURL: fileURL
            )
            .frame(width: 240)
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        ZStack {
            EditorView(
                text: $document.text,
                fontSize: CGFloat(fontSize),
                fileURL: fileURL,
                mode: viewMode,
                positionSyncID: positionSyncID,
                findState: findState,
                outlineState: outlineState,
                extraBottomInset: BottomToolbar.pillHeight + 24,
                jumpToLineState: jumpToLineState,
                statusBarState: statusBarState,
                contentWidthEm: contentWidthEm
            )
            .opacity(viewMode == .edit ? 1 : 0)
            .allowsHitTesting(viewMode == .edit)

            PreviewView(
                markdown: document.text,
                fontSize: CGFloat(fontSize) + 4,
                fontFamily: previewFontFamily,
                mode: viewMode,
                positionSyncID: positionSyncID,
                fileURL: fileURL,
                findState: findState,
                outlineState: outlineState,
                onTaskToggle: { line, checked in
                    toggleTask(line: line, checked: checked)
                },
                onLiveEdit: { start, end, original, text in
                    applyLiveEdit(start: start, end: end, original: original, text: text)
                },
                onLiveAppend: { text in
                    document.text = LiveEditSupport.appendingBlock(text, to: document.text)
                },
                contentWidthEm: contentWidthEm
            )
            .opacity(showsRenderedPane ? 1 : 0)
            .allowsHitTesting(showsRenderedPane)
        }
    }

    private var showsRenderedPane: Bool {
        viewMode == .preview || viewMode == .live
    }

    /// Replace source lines `start...end` (1-based, from the rendered page's
    /// data-sourcepos) with the block text the user typed in live mode.
    /// Compare-and-swap: the commit is dropped when those lines no longer
    /// contain `original` (e.g. the file changed on disk mid-edit).
    private func applyLiveEdit(start: Int, end: Int, original: String, text: String) {
        guard let updated = LiveEditSupport.applyingEdit(to: document.text, start: start, end: end, original: original, replacement: text) else { return }
        guard updated != document.text else { return }
        document.text = updated
    }

    /// Toggle the `[ ]` / `[x]` on the source line that produced this rendered
    /// task. Called from the preview-side click handler.
    private func toggleTask(line: Int, checked: Bool) {
        let lines = document.text.components(separatedBy: "\n")
        guard line > 0, line <= lines.count else { return }
        let original = lines[line - 1]
        let updated: String
        if checked {
            updated = original.replacingOccurrences(of: "[ ]", with: "[x]", options: [], range: original.range(of: "[ ]"))
        } else {
            updated = original.replacingOccurrences(of: "[x]", with: "[ ]", options: .caseInsensitive, range: original.range(of: "[x]", options: .caseInsensitive))
        }
        guard updated != original else { return }
        var newLines = lines
        newLines[line - 1] = updated
        document.text = newLines.joined(separator: "\n")
    }

    /// File ▸ Open Folder…: orient this window's sidebar to a chosen folder.
    private func openFolder() {
        guard let url = FolderPanel.choose() else { return }
        folderState.open(folder: url)
        sidebarMode = .folder
        outlineState.isVisible = true
    }

    private func newFile(tabbingInto window: NSWindow? = nil) {
        createMarkdownDocument(in: folderState, promptForFolder: true, tabbingInto: window)
    }

    private func orientSidebarToDocumentFolder() {
        guard let folder = fileURL?.deletingLastPathComponent() else { return }
        folderState.open(folder: folder)
    }

    private func exportPDF() {
        PDFExporter().exportPDF(
            markdown: document.text,
            fontSize: CGFloat(fontSize),
            fontFamily: previewFontFamily,
            fileURL: fileURL
        )
    }

    private func printDocument() {
        PDFExporter().printHTML(
            markdown: document.text,
            fontSize: CGFloat(fontSize),
            fontFamily: previewFontFamily,
            fileURL: fileURL
        )
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let fileURL: URL?
    let newFile: (NSWindow?) -> Void
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            let title = displayTitle(for: fileURL)
            if let window = nsView?.window {
                window.title = title
                configureDocumentWindowChrome(window)
                window.hypergraphiaNewFileAction = { [weak window] in
                    newFile(window)
                }
                onWindow(window)
            }

            guard let target = fileURL?.standardizedFileURL else { return }
            let document = NSDocumentController.shared.documents.first { document in
                document.fileURL?.standardizedFileURL == target
            }
            setDocumentTitle(document, for: fileURL)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.hypergraphiaNewFileAction = nil
    }
}
