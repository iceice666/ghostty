import XCTest

final class GhosttyTabSidebarTests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(
            """
            window-tab-bar-position = left
            window-show-tab-bar = auto
            """
        )
    }

    @MainActor
    func testSplitRowsAndFocusAcrossTabs() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(title(app, "sidebar-split-1").exists)

        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(title(app, "sidebar-split-2").waitForExistence(timeout: 5))

        title(app, "sidebar-split-1").click()
        expectSelected(row(app, "sidebar-split-1"))
        title(app, "sidebar-split-2").click()
        expectSelected(row(app, "sidebar-split-2"))

        // Selecting a row in an inactive tab must activate that tab and pane.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(title(app, "sidebar-tab-2").waitForExistence(timeout: 5))
        expectSelected(row(app, "sidebar-tab-2"))
        title(app, "sidebar-split-1").click()
        expectSelected(row(app, "sidebar-split-1"))

        // A zoomed sibling must be revealed before it can receive focus.
        app.typeKey("\n", modifierFlags: [.command, .shift])
        title(app, "sidebar-split-2").click()
        expectSelected(row(app, "sidebar-split-2"))
    }

    @MainActor
    func testCollapseAndCloseSplit() throws {
        try updateConfig(
            """
            window-tab-bar-position = left
            window-show-tab-bar = always
            confirm-close-surface = false
            """
        )
        let app = try ghosttyApplication()
        app.launch()
        let closeTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close tab:'")).firstMatch
        XCTAssertTrue(closeTab.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        let collapse = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Collapse splits:'")).firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        XCTAssertFalse(closeTab.exists)
        collapse.click()
        let expand = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Expand splits:'")).firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expectGone(title(app, "sidebar-split-1"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close split '")).count, 0)
        expand.click()
        let closeSplit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close split 2:'")).firstMatch
        XCTAssertTrue(closeSplit.waitForExistence(timeout: 5))
        closeSplit.click()
        // Closing one pane must leave its sibling alive and restore the tab close action.
        XCTAssertTrue(closeTab.waitForExistence(timeout: 5))
        XCTAssertFalse(collapse.exists)
        XCTAssertFalse(title(app, "sidebar-split-1").exists)
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    @MainActor
    func testCollapseSidebarToRail() throws {
        try updateConfig(
            """
            window-tab-bar-position = left
            window-show-tab-bar = always
            """
        )
        let app = try ghosttyApplication()
        app.launch()
        let collapse = app.buttons["Collapse Sidebar"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        collapse.click()
        // The rail keeps tab rows (icons) but drops titles and close buttons.
        let expand = app.buttons["Expand Sidebar"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close tab:'"))
            .allElementsBoundByIndex.filter(\.isHittable).count, 0)
        expand.click()
        XCTAssertTrue(app.buttons["Collapse Sidebar"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDragReordersTabs() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        // The dragged tab has expanded splits: its rows must move with it.
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(title(app, "sidebar-split-2").waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(title(app, "sidebar-tab-2").waitForExistence(timeout: 5))
        // The new tab is selected; drag the first tab below it.
        let first = row(app, "sidebar-tab-1")
        let second = row(app, "sidebar-tab-2")
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        // The selected tab (previously second) is now first and still selected.
        expectSelected(row(app, "sidebar-tab-1"))
        // Two tabs plus two split rows, nothing hidden or duplicated.
        let rows = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.outlineRows.count == 4 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rows], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts.matching(identifier: "sidebar-split-1").count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "sidebar-split-2").count, 1)
    }

    @MainActor
    func testDragTabOutsideWindowTearsOff() throws {
        let app = try ghosttyApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(title(app, "sidebar-tab-2").waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)

        // Release the first tab (with splits) over the terminal area; this must
        // work even when the window fills the screen.
        let outside = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        row(app, "sidebar-tab-1").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: outside)
        let twoWindows = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.windows.count == 2 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [twoWindows], timeout: 5), .completed)
        // With `auto`, the torn-off tab keeps its sidebar (tab + two split rows)
        // and the remaining lone, unsplit tab hides its sidebar.
        let rows = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.outlineRows.count == 3 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rows], timeout: 5), .completed)
    }

    @MainActor
    func testDragSplitRowOutsideWindowOpensWindow() throws {
        let app = try ghosttyApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(title(app, "sidebar-split-2").waitForExistence(timeout: 5))

        // Same semantics as dragging a pane: outside every window -> new window.
        let outside = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -150, dy: 0))
        row(app, "sidebar-split-2").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: outside)
        let twoWindows = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.windows.count == 2 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [twoWindows], timeout: 5), .completed)
        // Neither window has splits left, so `auto` hides both sidebars.
        expectGone(title(app, "sidebar-split-1"))
    }

    @MainActor
    private func title(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.staticTexts[identifier]
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.outlineRows.containing(.staticText, identifier: identifier).firstMatch
    }

    @MainActor
    private func expectSelected(_ element: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    @MainActor
    private func expectGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}
