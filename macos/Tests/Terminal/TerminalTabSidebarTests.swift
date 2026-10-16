import AppKit
import SwiftUI
import Testing
@testable import Ghostty

struct TerminalTabSidebarTests {
    @Test func reorderedIndex() {
        // Dropping before the tab itself or directly after it is a no-op.
        #expect(TabSidebarLayout.reorderedIndex(source: 1, destination: 1, count: 3) == nil)
        #expect(TabSidebarLayout.reorderedIndex(source: 1, destination: 2, count: 3) == nil)
        // Destinations are expressed in the original order.
        #expect(TabSidebarLayout.reorderedIndex(source: 0, destination: 3, count: 3) == 2)
        #expect(TabSidebarLayout.reorderedIndex(source: 0, destination: 2, count: 3) == 1)
        #expect(TabSidebarLayout.reorderedIndex(source: 2, destination: 0, count: 3) == 0)
        // Out-of-range values are rejected.
        #expect(TabSidebarLayout.reorderedIndex(source: 3, destination: 0, count: 3) == nil)
        #expect(TabSidebarLayout.reorderedIndex(source: 0, destination: 4, count: 3) == nil)
    }

    @Test func resolveDraggedWidth() {
        let collapsed = TabSidebarLayout.resolve(proposedWidth: TabSidebarLayout.collapseThreshold - 1)
        #expect(collapsed.collapsed)
        #expect(collapsed.width == nil)

        let narrow = TabSidebarLayout.resolve(proposedWidth: TabSidebarLayout.collapseThreshold + 1)
        #expect(!narrow.collapsed)
        #expect(narrow.width == TabSidebarLayout.minWidth)

        let wide = TabSidebarLayout.resolve(proposedWidth: 10_000)
        #expect(wide.width == TabSidebarLayout.maxWidth)
        #expect(TabSidebarLayout.resolve(proposedWidth: 250).width == 250)
    }

    @Test func statusAggregatePriority() {
        #expect(TabSidebarStatus.aggregate([]) == .none)
        #expect(TabSidebarStatus.aggregate([.bell, .exited(success: true)]) == .bell)
        #expect(TabSidebarStatus.aggregate([.bell, .notification]) == .notification)
        #expect(TabSidebarStatus.aggregate([.progress(.set, 40), .bell]) == .bell)
        #expect(TabSidebarStatus.aggregate([.notification, .exited(success: false)]) == .exited(success: false))
        #expect(TabSidebarStatus.aggregate([.exited(success: false), .progress(.error, 10)]) == .progress(.error, 10))
    }

    @Test @MainActor func containerResizesSidebarInPlace() {
        let container = TerminalViewContainer { EmptyView() }
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        container.setTabSidebar(sidebar, position: .right, width: 240)
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.frame.width == 240)
        #expect(sidebar.frame.minX == 560)

        container.setTabSidebarWidth(TabSidebarLayout.collapsedWidth)
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.frame.width == TabSidebarLayout.collapsedWidth)
        #expect(sidebar.frame.maxX == 800)
        #expect(container.frame.width == 800)

        // Re-attaching the same sidebar only updates the width.
        container.setTabSidebar(sidebar, position: .right, width: 300)
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.frame.width == 300)
    }
}
