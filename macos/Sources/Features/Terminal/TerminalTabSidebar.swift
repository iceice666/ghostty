import AppKit

/// A presentation of AppKit's native window tab group, not a separate tab model.
/// Actions deliberately go through TerminalController so close confirmations,
/// undo, and new-tab configuration are identical to the native tab bar.
final class TerminalTabSidebar {
    private weak var controller: TerminalController?
    private weak var observedGroup: NSWindowTabGroup?
    private var windowObservation: NSKeyValueObservation?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var refreshPending = false
    private var position: Ghostty.Config.WindowTabBarPosition = .top
    private var visibility = "auto"
    private var hiddenFallbackPosition: Ghostty.Config.WindowTabBarPosition?
    private var restoreNativeBar = false
    private let stack = TabSidebarStackView()
    let view = NSVisualEffectView()

    init(controller: TerminalController) {
        self.controller = controller
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        view.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    func configure(_ config: Ghostty.Config) {
        // Restoration cannot depend on which member happened to hide the shared
        // native bar: that member may have been closed before this reload.
        if position != .top && config.windowTabBarPosition == .top {
            restoreNativeBar = true
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
        refresh()
        if !needsSidebar {
            windowObservation = nil
            groupObservations.removeAll()
            titleObservations.removeAll()
            observedGroup = nil
        }
    }

    /// Hidden titlebars cannot display native tabs. Keep existing groups
    /// navigable after a side-to-top reload until their last extra tab closes.
    private var needsSidebar: Bool {
        position != .top || hiddenFallbackPosition != nil
    }

    private func scheduleRefresh() {
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
            if restoreNativeBar, let group = window.tabGroup,
               !group.isTabBarVisible, group.windows.count > 1 {
                window.toggleTabBar(nil)
            }
            restoreNativeBar = false
            windowObservation = nil
            groupObservations.removeAll()
            titleObservations.removeAll()
            observedGroup = nil
            return
        }

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
                    group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
                        self?.scheduleRefresh()
                    },
                ]
            }
        }
        if group?.isTabBarVisible == true {
            restoreNativeBar = true
            window.toggleTabBar(nil)
        }

        let windows = group?.windows ?? [window]
        let fallback = position == .top
        let show = fallback || visibility == "always" || (visibility != "never" && windows.count > 1)
        container.setTabSidebar(show ? view : nil, position: hiddenFallbackPosition ?? position)
        titleObservations = windows.map { tabWindow in
            tabWindow.observe(\.title, options: [.new]) { [weak self] _, _ in
                self?.scheduleRefresh()
            }
        }
        for child in stack.arrangedSubviews {
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        guard show else { return }

        for (index, tabWindow) in windows.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 4
            let select = NSButton(title: tabWindow.title, target: self, action: #selector(selectTab(_:)))
            select.tag = index
            select.bezelStyle = .recessed
            select.setButtonType(.pushOnPushOff)
            select.state = (group?.selectedWindow ?? window) === tabWindow ? .on : .off
            select.alignment = .left
            select.lineBreakMode = .byTruncatingTail
            select.toolTip = tabWindow.title
            select.setAccessibilityLabel("Select tab: \(tabWindow.title)")
            select.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!,
                                 target: self, action: #selector(closeTab(_:)))
            close.tag = index
            close.isBordered = false
            close.toolTip = "Close Tab"
            row.addArrangedSubview(select)
            row.addArrangedSubview(close)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            close.widthAnchor.constraint(equalToConstant: 20).isActive = true
        }
        let newTab = NSButton(title: "New Tab", target: self, action: #selector(addTab(_:)))
        newTab.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newTab.bezelStyle = .recessed
        stack.addArrangedSubview(newTab)
    }

    private func targetWindow(for sender: NSButton) -> NSWindow? {
        guard let window = controller?.window else { return nil }
        let windows = window.tabGroup?.windows ?? [window]
        guard windows.indices.contains(sender.tag) else { return nil }
        return windows[sender.tag]
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard let window = targetWindow(for: sender) else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        if let surface = (window.windowController as? TerminalController)?.focusedSurface {
            window.makeFirstResponder(surface)
        }
    }

    @objc private func closeTab(_ sender: NSButton) {
        guard let window = targetWindow(for: sender),
              let target = window.windowController as? TerminalController else { return }
        // Select before confirming so the sheet is presented on the visible tab.
        selectTab(sender)
        target.closeTab(sender)
    }

    @objc private func addTab(_ sender: NSButton) {
        controller?.newTab(sender)
    }
}

/// Scroll documents start at the first tab and grow downwards. Do not constrain
/// the document's vertical position to the clip view: scrolling moves it.
private final class TabSidebarStackView: NSStackView {
    override var isFlipped: Bool { true }
}
