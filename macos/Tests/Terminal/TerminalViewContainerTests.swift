//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @Test @MainActor func sidebarLayoutAndRemoval() {
        let container = TerminalViewContainer { EmptyView() }
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        container.initialContentSize = NSSize(width: 640, height: 480)
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        container.setTabSidebar(sidebar, position: .left)
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.superview === container)
        #expect(sidebar.frame.width == 200)
        #expect(sidebar.frame.minX == 0)
        #expect(container.intrinsicContentSize.width == 840)

        container.setTabSidebar(sidebar, position: .right)
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.frame.minX == 600)
        #expect(sidebar.frame.height == 500)

        container.setTabSidebar(nil, position: .top)
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.superview == nil)
        #expect(container.intrinsicContentSize.width == 640)
    }

    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }
}
