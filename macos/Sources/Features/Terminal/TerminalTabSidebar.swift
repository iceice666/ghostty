import AppKit
import Combine
import SwiftUI

/// Sidebar layout preferences. They are global so every tab of a group (each
/// tab is its own window with its own sidebar instance) shows the same layout.
enum TabSidebarLayout {
    static let defaultWidth: CGFloat = 200
    static let minWidth: CGFloat = 140
    static let maxWidth: CGFloat = 420
    static let collapsedWidth: CGFloat = 52
    /// Dragging the sidebar narrower than this snaps it to the collapsed rail.
    static let collapseThreshold: CGFloat = 100
    static let didChange = Notification.Name("com.mitchellh.ghostty.tabSidebarLayoutDidChange")

    private static let widthKey = "TabSidebarWidth"
    private static let collapsedKey = "TabSidebarCollapsed"

    static var width: CGFloat {
        let stored = UserDefaults.standard.double(forKey: widthKey)
        return stored > 0 ? clamp(stored) : defaultWidth
    }

    static var collapsed: Bool {
        UserDefaults.standard.bool(forKey: collapsedKey)
    }

    static var effectiveWidth: CGFloat {
        collapsed ? collapsedWidth : width
    }

    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }

    /// Resolve a dragged width into the layout it represents.
    static func resolve(proposedWidth: CGFloat) -> (width: CGFloat?, collapsed: Bool) {
        proposedWidth < collapseThreshold ? (nil, true) : (clamp(proposedWidth), false)
    }

    static func update(width: CGFloat? = nil, collapsed: Bool? = nil) {
        let defaults = UserDefaults.standard
        var changed = false
        if let width, clamp(width) != self.width {
            defaults.set(Double(clamp(width)), forKey: widthKey)
            changed = true
        }
        if let collapsed, collapsed != self.collapsed {
            defaults.set(collapsed, forKey: collapsedKey)
            changed = true
        }
        if changed {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The final index of a tab dragged from `source` and dropped before
    /// `destination` (both in the original order), or nil for a no-op.
    static func reorderedIndex(source: Int, destination: Int, count: Int) -> Int? {
        guard (0..<count).contains(source), (0...count).contains(destination) else { return nil }
        let final = destination > source ? destination - 1 : destination
        return final == source ? nil : final
    }
}

/// The most important activity of a surface or tab, shown as a row badge.
enum TabSidebarStatus: Equatable {
    case none
    case exited(success: Bool)
    case progress(Ghostty.Action.ProgressReport.State, UInt8?)
    case bell
    case notification

    /// Higher values win when several surfaces of a tab report activity.
    var priority: Int {
        switch self {
        case .none: return 0
        case .exited(success: true): return 1
        case .progress(let state, _): return state == .error ? 6 : 2
        case .bell: return 3
        case .notification: return 4
        case .exited(success: false): return 5
        }
    }

    static func aggregate(_ statuses: [TabSidebarStatus]) -> TabSidebarStatus {
        statuses.max { $0.priority < $1.priority } ?? .none
    }

    static func of(_ surface: Ghostty.SurfaceView) -> TabSidebarStatus {
        var statuses: [TabSidebarStatus] = []
        if let report = surface.progressReport, report.state != .remove {
            statuses.append(.progress(report.state, report.progress))
        }
        if surface.unreadNotification { statuses.append(.notification) }
        if surface.bell { statuses.append(.bell) }
        if let message = surface.childExitedMessage {
            statuses.append(.exited(success: message.level == .success))
        }
        return aggregate(statuses)
    }

    var accessibilityDescription: String? {
        switch self {
        case .none: return nil
        case .exited(success: true): return "Process exited"
        case .exited(success: false): return "Process failed"
        case .bell: return "Bell"
        case .notification: return "Unread notification"
        case .progress(let state, let progress):
            switch state {
            case .error: return "Progress error"
            case .pause: return "Progress paused"
            default: return progress.map { "Progress \($0)%" } ?? "In progress"
            }
        }
    }
}

/// A presentation of AppKit's native window tab group, not a separate tab model.
/// Actions deliberately go through TerminalController so close confirmations,
/// undo, and new-tab configuration are identical to the native tab bar.
final class TerminalTabSidebar: NSObject {
    private static let dragType = NSPasteboard.PasteboardType("com.mitchellh.ghostty.sidebar-tab")

    private weak var controller: TerminalController?
    private weak var observedGroup: NSWindowTabGroup?
    private var windowObservation: NSKeyValueObservation?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var surfaceObservations: Set<AnyCancellable> = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var flagsMonitor: Any?
    private var refreshPending = false
    private var position: Ghostty.Config.WindowTabBarPosition = .top
    private var visibility = "auto"
    private var hiddenFallbackPosition: Ghostty.Config.WindowTabBarPosition?

    /// The structure observed by `surfaceObservations`.
    private var observedStructure: Structure?
    /// The structure currently loaded into the outline view.
    private var loadedStructure: Structure?
    private var tabs: [TabNode] = []
    private var syncingSelection = false
    private var dragInProgress = false
    private weak var draggedWindow: NSWindow?
    private weak var draggedSurface: Ghostty.SurfaceView?
    private var escapeMonitor: Any?
    private var dragCancelledByEscape = false
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var tabShortcuts: [KeyboardShortcut?] = []
    private var resizeStartWidth: CGFloat = 0

    let view = NSVisualEffectView()
    private let outline = TabSidebarOutlineView()
    private let footer = NSStackView()
    private let newTabButton = TabSidebarActionButton()
    private let collapseButton = TabSidebarActionButton()
    private let resizeHandle = TabSidebarResizeHandle()
    private var handleConstraints: [NSLayoutConstraint] = []
    private var footerKey: String?

    init(controller: TerminalController) {
        self.controller = controller
        super.init()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        view.translatesAutoresizingMaskIntoConstraints = false
        setupOutline()
        setupFooter()
        setupResizeHandle()
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: TabSidebarLayout.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.layoutDidChange()
            },
            // Modifier releases go elsewhere once the window loses key status.
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.controller?.window else { return }
                self.setHeldModifiers([])
            },
        ]
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    // MARK: Setup

    private func setupOutline() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 0
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        // Keep keyboard focus in the terminal; rows are activated by clicking.
        outline.refusesFirstResponder = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // Not `.gap`: gap feedback hides the dragged row while leaving its split
        // children visible, and expects the outline to be updated synchronously
        // on drop. The tab group is updated (and observed) asynchronously.
        outline.draggingDestinationFeedbackStyle = .regular
        outline.setAccessibilityLabel("Tabs")
        scroll.documentView = outline

        view.addSubview(scroll)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
    }

    private func setupFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        footer.spacing = 4

        newTabButton.title = "New Tab"
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newTabButton.imagePosition = .imageLeading
        newTabButton.imageHugsTitle = true
        newTabButton.isBordered = false
        newTabButton.font = .systemFont(ofSize: 13)
        newTabButton.alignment = .left
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.toolTip = "New Tab"
        newTabButton.setAccessibilityLabel("New Tab")
        newTabButton.handler = { [weak self] in self?.controller?.newTab(nil) }

        collapseButton.isBordered = false
        collapseButton.imagePosition = .imageOnly
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        collapseButton.handler = { TabSidebarLayout.update(collapsed: !TabSidebarLayout.collapsed) }

        footer.addArrangedSubview(newTabButton)
        footer.addArrangedSubview(collapseButton)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            newTabButton.heightAnchor.constraint(equalToConstant: 28),
            collapseButton.widthAnchor.constraint(equalToConstant: 28),
            collapseButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        updateFooter()
    }

    private func updateFooter() {
        let collapsed = TabSidebarLayout.collapsed
        let key = "\(collapsed)-\(hiddenFallbackPosition ?? position)"
        guard key != footerKey else { return }
        footerKey = key
        footer.orientation = collapsed ? .vertical : .horizontal
        footer.alignment = collapsed ? .centerX : .centerY
        newTabButton.imagePosition = collapsed ? .imageOnly : .imageLeading
        newTabButton.setContentHuggingPriority(collapsed ? .required : .defaultLow, for: .horizontal)
        let symbol = (hiddenFallbackPosition ?? position) == .right ? "sidebar.right" : "sidebar.left"
        let label = collapsed ? "Expand Sidebar" : "Collapse Sidebar"
        collapseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        collapseButton.toolTip = label
        collapseButton.setAccessibilityLabel(label)
    }

    private func setupResizeHandle() {
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resizeHandle)
        resizeHandle.onBegin = { [weak self] in
            self?.resizeStartWidth = TabSidebarLayout.effectiveWidth
        }
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            let sign: CGFloat = (self.hiddenFallbackPosition ?? self.position) == .right ? -1 : 1
            let resolved = TabSidebarLayout.resolve(proposedWidth: self.resizeStartWidth + sign * delta)
            TabSidebarLayout.update(width: resolved.width, collapsed: resolved.collapsed)
        }
        resizeHandle.onDoubleClick = {
            TabSidebarLayout.update(collapsed: !TabSidebarLayout.collapsed)
        }
        updateResizeHandle()
    }

    private func updateResizeHandle() {
        let right = (hiddenFallbackPosition ?? position) == .right
        let edge: NSRectEdge = right ? .minX : .maxX
        guard handleConstraints.isEmpty || resizeHandle.edge != edge else { return }
        NSLayoutConstraint.deactivate(handleConstraints)
        resizeHandle.edge = right ? .minX : .maxX
        handleConstraints = [
            resizeHandle.topAnchor.constraint(equalTo: view.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 6),
            right
                ? resizeHandle.leadingAnchor.constraint(equalTo: view.leadingAnchor)
                : resizeHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        NSLayoutConstraint.activate(handleConstraints)
    }

    // MARK: Configuration

    func configure(_ config: Ghostty.Config) {
        if position != .top && config.windowTabBarPosition == .top {
            if controller?.window is HiddenTitlebarTerminalWindow,
               (controller?.window?.tabGroup?.windows.count ?? 0) > 1 {
                hiddenFallbackPosition = position
            }
        } else if config.windowTabBarPosition != .top {
            hiddenFallbackPosition = nil
        }
        position = config.windowTabBarPosition
        visibility = config.windowShowTabBar
        // Do not materialize native tab groups for the default top position.
        if needsSidebar, windowObservation == nil, let window = controller?.window {
            windowObservation = window.observe(\.tabGroup, options: [.new]) { [weak self] _, _ in
                self?.scheduleRefresh()
            }
        }
        // Keybinds may have changed.
        observedStructure = nil
        loadedStructure = nil
        refresh()
        if !needsSidebar {
            stopObserving()
        }
    }

    /// Hidden titlebars cannot display native tabs. Keep existing groups
    /// navigable after a side-to-top reload until their last extra tab closes.
    private var needsSidebar: Bool {
        position != .top || hiddenFallbackPosition != nil
    }

    private func stopObserving() {
        surfaceObservations.removeAll()
        windowObservation = nil
        groupObservations.removeAll()
        titleObservations.removeAll()
        observedGroup = nil
        observedStructure = nil
        loadedStructure = nil
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    private func layoutDidChange() {
        guard needsSidebar else { return }
        controller?.terminalViewContainer?.setTabSidebarWidth(TabSidebarLayout.effectiveWidth)
        updateFooter()
        scheduleRefresh()
    }

    // MARK: Refresh

    /// Identity of the rows. A change requires reloading the outline; any other
    /// change (titles, badges, focus) only reconfigures the visible rows.
    private struct Structure: Equatable {
        var windows: [ObjectIdentifier]
        var surfaces: [[UUID]]
        var compact: Bool
    }

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    func refresh() {
        guard let controller, let window = controller.window,
              let container = controller.terminalViewContainer else { return }
        if hiddenFallbackPosition != nil, (window.tabGroup?.windows.count ?? 0) < 2 {
            hiddenFallbackPosition = nil
        }
        guard needsSidebar else {
            container.setTabSidebar(nil, position: .top)
            (window as? TerminalWindow)?.hidesNativeTabBar = false
            stopObserving()
            return
        }

        // Hide the native bar for this window instead of calling toggleTabBar.
        // toggleTabBar flips state shared by the whole tab group, so multiple
        // controllers refreshing for the same tab change can show it again.
        (window as? TerminalWindow)?.hidesNativeTabBar = true

        let group = window.tabGroup
        if observedGroup !== group {
            observedGroup = group
            groupObservations.removeAll()
            if let group {
                groupObservations = [
                    group.observe(\.windows, options: [.new]) { [weak self] _, _ in
                        self?.scheduleRefresh()
                    },
                    group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                        self?.scheduleRefresh()
                    },
                ]
            }
        }
        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.modifiersChanged(event)
                return event
            }
        }

        let windows = group?.windows ?? [window]
        let compact = TabSidebarLayout.collapsed
        let structure = Structure(
            windows: windows.map(ObjectIdentifier.init),
            surfaces: windows.map { tabWindow in
                (tabWindow.windowController as? TerminalController).map { Array($0.surfaceTree).map(\.id) } ?? []
            },
            compact: compact)
        if structure != observedStructure {
            observe(windows)
            observedStructure = structure
        }

        // Observe even while hidden: the first split can make an auto sidebar visible.
        let hasSplits = structure.surfaces.contains { $0.count > 1 }
        let show = position == .top || visibility == "always" ||
            (visibility != "never" && (windows.count > 1 || hasSplits))
        container.setTabSidebar(
            show ? view : nil,
            position: hiddenFallbackPosition ?? position,
            width: TabSidebarLayout.effectiveWidth)
        updateResizeHandle()
        updateFooter()
        guard show else {
            loadedStructure = nil
            return
        }
        // Flag changes may have happened while another window was key.
        heldModifiers = window.isKeyWindow
            ? NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            : []

        // Never reload or re-expand rows under an active drag session; AppKit
        // still references them. The session end forces a full reload.
        if dragInProgress {
            reconfigureVisibleRows()
            return
        }

        if structure != loadedStructure {
            rebuildNodes(windows)
            loadedStructure = structure
            outline.reloadData()
            syncExpansion(animated: false)
            reconfigureVisibleRows()
        } else {
            syncExpansion(animated: true)
            reconfigureVisibleRows()
        }
        syncSelection()
    }

    private func observe(_ windows: [NSWindow]) {
        surfaceObservations.removeAll()
        let schedule: (Any) -> Void = { [weak self] _ in self?.scheduleRefresh() }
        for tabWindow in windows {
            guard let target = tabWindow.windowController as? TerminalController else { continue }
            target.$sidebarSplitsExpanded.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
            target.$surfaceTree.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
            for surface in target.surfaceTree {
                surface.$title.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
                surface.$focusInstant.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
                surface.$bell.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
                surface.$unreadNotification.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
                surface.$childExitedMessage.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
                surface.$progressReport.dropFirst().sink(receiveValue: schedule).store(in: &surfaceObservations)
            }
        }
        titleObservations = windows.map { tabWindow in
            tabWindow.observe(\.title, options: [.new]) { [weak self] _, _ in
                self?.scheduleRefresh()
            }
        }
        // Sidebar callbacks all run on the main thread (AppKit, KVO of windows,
        // and main-queue notifications).
        let config = controller?.ghostty.config
        tabShortcuts = MainActor.assumeIsolated {
            windows.indices.map { index in
                index < 9 ? config?.keyboardShortcut(for: "goto_tab:\(index + 1)") : nil
            }
        }
    }

    /// Reuse nodes so the outline view keeps item identity across reloads.
    private func rebuildNodes(_ windows: [NSWindow]) {
        let previous = Dictionary(tabs.compactMap { tab in tab.window.map { (ObjectIdentifier($0), tab) } },
                                  uniquingKeysWith: { first, _ in first })
        tabs = windows.map { tabWindow in
            let tab = previous[ObjectIdentifier(tabWindow)] ?? TabNode(window: tabWindow)
            let surfaces = tab.controller.map { Array($0.surfaceTree) } ?? []
            let oldSplits = Dictionary(tab.splits.compactMap { split in split.surface.map { ($0.id, split) } },
                                       uniquingKeysWith: { first, _ in first })
            tab.splits = surfaces.count > 1 ? surfaces.enumerated().map { index, surface in
                let split = oldSplits[surface.id] ?? SplitNode(surface: surface, tab: tab)
                split.index = index
                return split
            } : []
            return tab
        }
    }

    private func syncExpansion(animated: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            if !animated { context.duration = 0 }
            for tab in tabs where !tab.splits.isEmpty && !TabSidebarLayout.collapsed {
                let expanded = tab.controller?.sidebarSplitsExpanded ?? true
                if expanded, !outline.isItemExpanded(tab) {
                    outline.animator().expandItem(tab)
                } else if !expanded, outline.isItemExpanded(tab) {
                    outline.animator().collapseItem(tab)
                }
            }
        }
    }

    private func reconfigureVisibleRows() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let item = outline.item(atRow: row),
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarCellView
            else { continue }
            configure(cell, for: item)
        }
    }

    private var selectedWindow: NSWindow? {
        controller?.window?.tabGroup?.selectedWindow ?? controller?.window
    }

    private func syncSelection() {
        guard let selectedWindow, let tab = tabs.first(where: { $0.window === selectedWindow }) else {
            outline.deselectAll(nil)
            return
        }
        var item: AnyObject = tab
        if outline.isItemExpanded(tab), let focused = tab.controller?.focusedSurface,
           let split = tab.splits.first(where: { $0.surface === focused }) {
            item = split
        }
        let row = outline.row(forItem: item)
        guard row >= 0, outline.selectedRow != row else { return }
        syncingSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        syncingSelection = false
        outline.scrollRowToVisible(row)
    }

    // MARK: Shortcut hints

    private func modifiersChanged(_ event: NSEvent) {
        setHeldModifiers(event.window === controller?.window
            ? event.modifierFlags.intersection([.command, .option, .control, .shift])
            : [])
    }

    private func setHeldModifiers(_ held: NSEvent.ModifierFlags) {
        guard held != heldModifiers else { return }
        heldModifiers = held
        guard view.superview != nil else { return }
        reconfigureVisibleRows()
    }

    private func hint(forTabAt index: Int) -> String? {
        guard !heldModifiers.isEmpty, tabShortcuts.indices.contains(index),
              let shortcut = tabShortcuts[index] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        return flags == heldModifiers ? shortcut.description : nil
    }

    // MARK: Row content

    private func configure(_ cell: TabSidebarCellView, for item: Any) {
        let compact = TabSidebarLayout.collapsed
        if let tab = item as? TabNode, let window = tab.window {
            let index = tabs.firstIndex { $0 === tab } ?? 0
            let surfaces = tab.controller.map { Array($0.surfaceTree) } ?? []
            let expanded = !compact && surfaces.count > 1 && (tab.controller?.sidebarSplitsExpanded ?? true)
            let title = window.title
            let action: TabSidebarCellView.Action
            let actionLabel: String
            if compact || surfaces.count <= 1 {
                action = .close
                actionLabel = "Close tab: \(title)"
            } else {
                action = expanded ? .collapse : .expand
                actionLabel = "\(expanded ? "Collapse splits" : "Expand splits"): \(title)"
            }
            // Expanded splits show their own badges.
            let status = expanded ? .none : TabSidebarStatus.aggregate(surfaces.map(TabSidebarStatus.of))
            cell.apply(.init(
                title: title,
                symbol: "terminal",
                indent: 10,
                compact: compact,
                emphasized: window === selectedWindow,
                status: status,
                hint: hint(forTabAt: index),
                action: action,
                actionLabel: actionLabel,
                identifier: "sidebar-tab-\(index + 1)",
                accessibilityLabel: "Tab: \(title)"))
            cell.onAction = { [weak self, weak tab] in
                guard let self, let tab else { return }
                switch action {
                case .close: self.closeTab(tab)
                case .collapse, .expand: tab.controller?.sidebarSplitsExpanded.toggle()
                }
            }
        } else if let split = item as? SplitNode, let surface = split.surface {
            let title = surface.title.isEmpty ? "Split \(split.index + 1)" : surface.title
            cell.apply(.init(
                title: title,
                symbol: "rectangle.split.2x1",
                indent: 26,
                compact: compact,
                emphasized: false,
                status: .of(surface),
                hint: nil,
                action: .close,
                actionLabel: "Close split \(split.index + 1): \(title)",
                identifier: "sidebar-split-\(split.index + 1)",
                accessibilityLabel: "Split \(split.index + 1): \(title)"))
            cell.onAction = { [weak self, weak split] in
                guard let self, let split else { return }
                self.closeSplit(split)
            }
        }
    }

    // MARK: Actions

    @objc private func rowClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let tab = item as? TabNode {
            activate(tab)
        } else if let split = item as? SplitNode {
            selectSplit(split)
        }
        // Reflect the click immediately; focus changes resync it afterwards.
        syncingSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        syncingSelection = false
    }

    private func activate(_ tab: TabNode) {
        guard let window = tab.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        if let surface = tab.controller?.focusedSurface {
            window.makeFirstResponder(surface)
        }
    }

    private func selectSplit(_ split: SplitNode) {
        guard let target = split.tab?.controller, let surface = split.surface,
              target.surfaceTree.contains(surface), let window = target.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        // A zoomed sibling is not attached to the window. Reveal the whole tree
        // before using the normal focus path, which waits for view attachment.
        if target.surfaceTree.zoomed != nil {
            target.surfaceTree = SplitTree(root: target.surfaceTree.root, zoomed: nil)
        }
        target.focusSurface(surface)
    }

    private func closeSplit(_ split: SplitNode) {
        guard let target = split.tab?.controller, let surface = split.surface,
              target.surfaceTree.contains(surface), let handle = surface.surface,
              let window = target.window else { return }
        // Present any confirmation on the correct tab, without asynchronously
        // scheduling focus on a surface that is about to be removed.
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        target.ghostty.requestClose(surface: handle)
    }

    private func closeTab(_ tab: TabNode) {
        guard let target = tab.controller else { return }
        // Select before confirming so the sheet is presented on the visible tab.
        activate(tab)
        target.closeTab(nil)
    }

    /// Reorder through the native tab group so the native model stays the
    /// source of truth (same approach as the `move_tab` keybind).
    private func moveTab(from source: Int, to destination: Int) -> Bool {
        guard let group = controller?.window?.tabGroup else { return false }
        let windows = group.windows
        guard let final = TabSidebarLayout.reorderedIndex(
            source: source, destination: destination, count: windows.count) else { return false }
        let moving = windows[source]
        let selected = group.selectedWindow
        var others = windows
        others.remove(at: source)

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group.removeWindow(moving)
        let moved = final == 0
            ? others[0].addTabbedWindowSafely(moving, ordered: .below)
            : others[final - 1].addTabbedWindowSafely(moving, ordered: .above)
        if let selected {
            selected.tabGroup?.selectedWindow = selected
            selected.makeKey()
        }
        NSAnimationContext.endGrouping()

        (selected?.windowController as? TerminalController)?.relabelTabs()
        return moved
    }
}

// MARK: - Outline data source and delegate

extension TerminalTabSidebar: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tab = item as? TabNode else { return item == nil ? tabs.count : 0 }
        return TabSidebarLayout.collapsed ? 0 : tab.splits.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let tab = item as? TabNode { return tab.splits[index] }
        return tabs[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let tab = item as? TabNode else { return false }
        return !TabSidebarLayout.collapsed && !tab.splits.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if TabSidebarLayout.collapsed { return 40 }
        return item is TabNode ? 34 : 28
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        TabSidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TabSidebarCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TabSidebarCellView
            ?? TabSidebarCellView(identifier: identifier)
        configure(cell, for: item)
        return cell
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        // Selection mirrors the focused tab and pane. Clicks are handled on
        // mouse-up in rowClicked so a drag never switches tabs mid-gesture.
        syncingSelection ? proposedSelectionIndexes : outlineView.selectedRowIndexes
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        syncSelection()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        syncSelection()
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Split rows carry the same payload as dragging a pane's grab handle, so
        // terminal panes accept them as split drops (also across windows).
        if let split = item as? SplitNode {
            return split.surface?.pasteboardItem()
        }
        guard tabs.count > 1, let tab = item as? TabNode, tab.window != nil else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("tab", forType: Self.dragType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        dragInProgress = true
        draggedWindow = (draggedItems.first as? TabNode)?.window
        draggedSurface = (draggedItems.first as? SplitNode)?.surface
        // A failed drop may tear the item off where it was released, so do not
        // slide the drag image back to the sidebar first.
        session.animatesToStartingPositionsOnCancelOrFail = false
        dragCancelledByEscape = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dragCancelledByEscape = true }
            return event
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let dragged = draggedWindow
        let surface = draggedSurface
        dragInProgress = false
        draggedWindow = nil
        draggedSurface = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        defer {
            // Rebuild from the tab group whether the drop succeeded, was
            // cancelled, or ended outside the sidebar.
            loadedStructure = nil
            refresh()
        }
        guard operation.isEmpty, !dragCancelledByEscape else { return }

        // Split rows behave exactly like dragging a pane: released outside
        // every window, the pane moves into a new window at that point.
        if let surface {
            let endsInWindow = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
            let target = endsInWindow ? Self.paneDropTarget(at: screenPoint) : nil
            Ghostty.logger.debug(
                "sidebar split drag ended point=\(NSStringFromPoint(screenPoint), privacy: .public) endsInWindow=\(endsInWindow) zone=\(target?.zone.rawValue ?? "none", privacy: .public) self=\(target?.destination === surface)"
            )
            if !endsInWindow {
                NotificationCenter.default.post(
                    name: .ghosttySurfaceDragEndedNoTarget,
                    object: surface,
                    userInfo: [Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey: screenPoint])
            } else if let target, target.destination !== surface {
                // The panes' SwiftUI drop zones do not accept drags that start
                // in the sidebar's outline view, so perform the same split drop
                // directly on the pane under the pointer.
                target.controller.performSplitAction(.drop(.init(
                    payload: surface, destination: target.destination, zone: target.zone)))
            }
            return
        }

        // Like the native tab bar: releasing a tab anywhere outside the sidebar
        // (including over the terminal, so it also works for maximized and
        // fullscreen windows) moves it into a new window at that point.
        let sidebarFrame = view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) }
        let outside = sidebarFrame.map { !$0.contains(screenPoint) } ?? false
        let canTearOff = (dragged?.tabGroup?.windows.count ?? 0) > 1
        Ghostty.logger.debug(
            "sidebar tab drag ended point=\(NSStringFromPoint(screenPoint), privacy: .public) operation=\(operation.rawValue) outside=\(outside) canTearOff=\(canTearOff)"
        )
        if outside, canTearOff, let dragged {
            tearOff(dragged, at: screenPoint)
        }
    }

    /// The frontmost terminal pane under a screen point, and the split zone
    /// computed exactly like the panes' own drop delegate (top-left origin).
    private static func paneDropTarget(at screenPoint: NSPoint) -> (
        controller: BaseTerminalController, destination: Ghostty.SurfaceView, zone: TerminalSplitDropZone
    )? {
        // Skip non-terminal windows (AppKit overlays, tooltips, panels) that
        // can be ordered above the terminal under the pointer.
        let candidates = NSApp.orderedWindows.filter { $0.isVisible && $0.frame.contains(screenPoint) }
        Ghostty.logger.debug(
            "sidebar pane lookup windows=\(candidates.map { "\(type(of: $0))/\(type(of: $0.windowController as Any))" }, privacy: .public)"
        )
        guard let window = candidates.first(where: { $0.windowController is BaseTerminalController }),
              let controller = window.windowController as? BaseTerminalController else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        for surface in controller.surfaceTree where surface.window === window {
            let point = surface.convert(windowPoint, from: nil)
            Ghostty.logger.debug(
                "sidebar pane lookup surface=\(NSStringFromRect(surface.bounds), privacy: .public) point=\(NSStringFromPoint(point), privacy: .public)"
            )
            guard surface.bounds.contains(point) else { continue }
            let size = surface.bounds.size
            let topLeft = CGPoint(x: point.x, y: surface.isFlipped ? point.y : size.height - point.y)
            return (controller, surface, .calculate(at: topLeft, in: size))
        }
        return nil
    }

    private func tearOff(_ window: NSWindow, at screenPoint: NSPoint) {
        // AppKit's own action keeps the controller, splits, and undo intact.
        // Select the tab first: the action is meant for the visible tab.
        window.tabGroup?.selectedWindow = window
        window.moveTabToNewWindow(nil)
        // AppKit cascades the new window; move it after it has been placed so
        // the titlebar sits under the pointer.
        DispatchQueue.main.async {
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 80, y: screenPoint.y + 12))
            window.constrainToScreen()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let source = draggedIndex(info) else { return [] }
        let destination: Int
        if item == nil, index >= 0 {
            destination = index
        } else if let tab = item as? TabNode, let tabIndex = tabs.firstIndex(where: { $0 === tab }) {
            // Dropping onto a tab or among its splits places the tab next to it.
            destination = index >= 0 || source < tabIndex ? tabIndex + 1 : tabIndex
        } else if let split = item as? SplitNode, let tab = split.tab,
                  let tabIndex = tabs.firstIndex(where: { $0 === tab }) {
            destination = tabIndex + 1
        } else {
            return []
        }
        guard TabSidebarLayout.reorderedIndex(source: source, destination: destination, count: tabs.count) != nil
        else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: destination)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard item == nil, let source = draggedIndex(info) else { return false }
        return moveTab(from: source, to: index)
    }

    /// The dragged tab's index in the displayed rows, identified by window so
    /// a tab opened or closed mid-drag cannot redirect the move. Rows are
    /// frozen during a drag, so the drop is rejected if they went stale.
    private func draggedIndex(_ info: NSDraggingInfo) -> Int? {
        guard dragInProgress, info.draggingSource as? NSOutlineView === outline,
              let draggedWindow, let group = controller?.window?.tabGroup,
              group.windows.elementsEqual(tabs.compactMap(\.window), by: ===)
        else { return nil }
        return tabs.firstIndex { $0.window === draggedWindow }
    }
}

// MARK: - Nodes

private final class TabNode {
    weak var window: NSWindow?
    var splits: [SplitNode] = []

    init(window: NSWindow) {
        self.window = window
    }

    var controller: TerminalController? {
        window?.windowController as? TerminalController
    }
}

/// Stable, weak targets avoid focusing a different pane after a tree mutation.
private final class SplitNode {
    weak var surface: Ghostty.SurfaceView?
    weak var tab: TabNode?
    var index = 0

    init(surface: Ghostty.SurfaceView, tab: TabNode) {
        self.surface = surface
        self.tab = tab
    }
}

// MARK: - Views

/// Hides the disclosure triangle (splits use their own chevron button) and
/// gives every level the full row width; cells indent themselves.
private final class TabSidebarOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        let rowRect = rect(ofRow: row)
        return NSRect(x: rowRect.minX, y: frame.minY, width: rowRect.width, height: frame.height)
    }
}

private final class TabSidebarCellView: NSTableCellView {
    enum Action { case close, expand, collapse }

    struct Content {
        var title: String
        var symbol: String
        var indent: CGFloat
        var compact: Bool
        var emphasized: Bool
        var status: TabSidebarStatus
        var hint: String?
        var action: Action
        var actionLabel: String
        var identifier: String
        var accessibilityLabel: String
    }

    var onAction: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let status = TabSidebarStatusView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let actionButton = TabSidebarActionButton()
    private var iconLeading: NSLayoutConstraint!
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []
    private var isCompact: Bool?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        textField = label
        imageView = icon

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = .secondaryLabelColor
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        actionButton.handler = { [weak self] in self?.onAction?() }

        for view in [icon, label, status, hintLabel, actionButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 22),
            actionButton.heightAnchor.constraint(equalToConstant: 22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        expandedConstraints = [
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -4),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -2),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 14),
            status.heightAnchor.constraint(equalToConstant: 14),
        ]
        compactConstraints = [
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            status.centerXAnchor.constraint(equalTo: icon.trailingAnchor),
            status.centerYAnchor.constraint(equalTo: icon.topAnchor),
            status.widthAnchor.constraint(equalToConstant: 10),
            status.heightAnchor.constraint(equalToConstant: 10),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Hidden in the rail, but keep its layout unambiguous.
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content) {
        if isCompact != content.compact {
            NSLayoutConstraint.deactivate(content.compact ? expandedConstraints : compactConstraints)
            NSLayoutConstraint.activate(content.compact ? compactConstraints : expandedConstraints)
            isCompact = content.compact
        }
        iconLeading.constant = content.indent

        icon.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
        label.stringValue = content.title
        label.font = .systemFont(ofSize: content.indent > 10 ? 12 : 13,
                                 weight: content.emphasized ? .medium : .regular)
        label.isHidden = content.compact
        label.setAccessibilityIdentifier(content.identifier)
        hintLabel.stringValue = content.hint ?? ""
        hintLabel.isHidden = content.hint == nil
        // In the rail the shortcut replaces the icon; in the list it replaces the button.
        icon.isHidden = content.compact && content.hint != nil
        status.status = content.status

        let symbol: String
        switch content.action {
        case .close: symbol = "xmark"
        case .expand: symbol = "chevron.right"
        case .collapse: symbol = "chevron.down"
        }
        actionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: content.actionLabel)
        actionButton.toolTip = content.actionLabel.components(separatedBy: ":").first
        actionButton.setAccessibilityLabel(content.actionLabel)
        actionButton.isHidden = content.compact || content.hint != nil

        toolTip = content.title
        setAccessibilityLabel([content.accessibilityLabel, content.status.accessibilityDescription]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// Draws a badge for `TabSidebarStatus`.
private final class TabSidebarStatusView: NSView {
    private let spinner = NSProgressIndicator()
    private let imageView = NSImageView()

    var status: TabSidebarStatus = .none {
        didSet {
            guard oldValue != status else { return }
            update()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        for view in [spinner, imageView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func update() {
        isHidden = status == .none
        setAccessibilityLabel(status.accessibilityDescription)
        var symbol: (String, NSColor)?
        var spinning = false
        switch status {
        case .bell: symbol = ("bell.fill", .systemOrange)
        case .exited(success: true): symbol = ("checkmark.circle.fill", .systemGreen)
        case .exited(success: false): symbol = ("exclamationmark.circle.fill", .systemRed)
        case .progress(let state, let value):
            spinning = state == .indeterminate || (state == .set && value == nil)
        case .notification, .none: break
        }
        if let symbol {
            let (name, color) = symbol
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            imageView.contentTintColor = color
            imageView.isHidden = false
        } else {
            imageView.isHidden = true
        }
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let side = min(bounds.width, bounds.height)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        switch status {
        case .notification:
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: side * 0.2, dy: side * 0.2)).fill()
        case .progress(let state, let value) where state != .indeterminate && (value != nil || state != .set):
            let lineWidth = max(1.5, side / 7)
            let ring = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = lineWidth
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()
            let fraction = CGFloat(min(value ?? 100, 100)) / 100
            guard fraction > 0 else { return }
            let arc = NSBezierPath()
            let center = NSPoint(x: ring.midX, y: ring.midY)
            arc.appendArc(withCenter: center, radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            switch state {
            case .error: NSColor.systemRed.setStroke()
            case .pause: NSColor.systemYellow.setStroke()
            default: NSColor.controlAccentColor.setStroke()
            }
            arc.stroke()
        default:
            break
        }
    }
}

/// Full-width tab surfaces use semantic colors so light, dark, and increased
/// contrast appearances remain readable without the native blue button bezel.
private final class TabSidebarRowView: NSTableRowView {
    private var tracking: NSTrackingArea?
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    private var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0.5), xRadius: 8, yRadius: 8)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        // Rows can be reused while the pointer is stationary.
        isHovered = window.map {
            $0.isKeyWindow && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        shape.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let shape = self.shape
        NSColor.labelColor.withAlphaComponent(isHovered ? 0.12 : 0.08).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSColor.controlAccentColor.setFill()
        let barHeight = min(14, bounds.height - 12)
        NSBezierPath(roundedRect: NSRect(x: 6, y: bounds.midY - barHeight / 2, width: 3, height: barHeight),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Keep actions visible and keyboard-accessible, with their own hover target.
private class TabSidebarActionButton: NSButton {
    var handler: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(invoke(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke(_ sender: Any?) {
        handler?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        isHovered = window.map {
            $0.isKeyWindow && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// The draggable inner edge of the sidebar. Double-click toggles the rail.
private final class TabSidebarResizeHandle: NSView {
    var edge: NSRectEdge = .maxX {
        didSet { needsDisplay = true }
    }
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let x = edge == .maxX ? bounds.maxX - 1 : bounds.minX
        NSRect(x: x, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard let window else { return }
        let start = event.locationInWindow.x
        onBegin?()
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event, event.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            self.onDrag?(event.locationInWindow.x - start)
        }
        window.invalidateCursorRects(for: self)
    }
}
