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
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

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
            (window as? TerminalWindow)?.hidesNativeTabBar = false
            windowObservation = nil
            groupObservations.removeAll()
            titleObservations.removeAll()
            observedGroup = nil
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
            let row = TabSidebarRowView(isSelected: (group?.selectedWindow ?? window) === tabWindow)
            let select = NSButton(title: tabWindow.title, target: self, action: #selector(selectTab(_:)))
            select.tag = index
            select.isBordered = false
            select.font = .systemFont(ofSize: 13, weight: row.isSelected ? .medium : .regular)
            select.contentTintColor = .labelColor
            select.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            select.imagePosition = .imageLeading
            select.imageHugsTitle = true
            select.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            select.setAccessibilityValue(row.isSelected ? "Selected" : "Not selected")
            select.alignment = .left
            select.lineBreakMode = .byTruncatingTail
            select.toolTip = tabWindow.title
            select.setAccessibilityLabel("Select tab: \(tabWindow.title)")
            select.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let close = TabSidebarActionButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!,
                                 target: self, action: #selector(closeTab(_:)))
            close.tag = index
            close.isBordered = false
            close.toolTip = "Close Tab"
            close.setAccessibilityLabel("Close tab: \(tabWindow.title)")
            close.contentTintColor = .secondaryLabelColor
            close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            select.translatesAutoresizingMaskIntoConstraints = false
            close.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(select)
            row.addSubview(close)
            row.selectionButton = select
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
                row.heightAnchor.constraint(equalToConstant: 36),
                select.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                select.topAnchor.constraint(equalTo: row.topAnchor),
                select.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                select.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
                close.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
                close.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                close.widthAnchor.constraint(equalToConstant: 24),
                close.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        let newTab = TabSidebarActionButton(title: "New Tab", target: self, action: #selector(addTab(_:)))
        newTab.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newTab.imagePosition = .imageLeading
        newTab.imageHugsTitle = true
        newTab.isBordered = false
        newTab.font = .systemFont(ofSize: 13)
        newTab.contentTintColor = .secondaryLabelColor
        newTab.toolTip = "New Tab"
        if let lastRow = stack.arrangedSubviews.last {
            stack.setCustomSpacing(10, after: lastRow)
        }
        stack.addArrangedSubview(newTab)
        NSLayoutConstraint.activate([
            newTab.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            newTab.heightAnchor.constraint(equalToConstant: 32),
        ])
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

/// Full-width tab surfaces use semantic colors so light, dark, and increased
/// contrast appearances remain readable without the native blue button bezel.
private final class TabSidebarRowView: NSView {
    let isSelected: Bool
    weak var selectionButton: NSButton?
    private var tracking: NSTrackingArea?
    private var isHovered = false

    init(isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        selectionButton?.performClick(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        // Rows can be rebuilt while the pointer is stationary (e.g. title changes).
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
        super.draw(dirtyRect)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isSelected {
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.12 : 0.08).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 11, width: 3, height: 14),
                         xRadius: 1.5, yRadius: 1.5).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            shape.fill()
        }
    }
}

/// Keep close actions visible and keyboard-accessible, with their own hover target.
private final class TabSidebarActionButton: NSButton {
    private var tracking: NSTrackingArea?
    private var isHovered = false

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

/// Scroll documents start at the first tab and grow downwards. Do not constrain
/// the document's vertical position to the clip view: scrolling moves it.
private final class TabSidebarStackView: NSStackView {
    override var isFlipped: Bool { true }
}
