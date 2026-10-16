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
        let splits = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select split '"))
        XCTAssertEqual(splits.count, 0)

        app.typeKey("d", modifierFlags: .command)
        let splitRows = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in splits.count == 2 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [splitRows], timeout: 5), .completed)

        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select split 1:'")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select split 2:'")).firstMatch
        first.click()
        expectSelected(first)
        second.click()
        expectSelected(second)

        // Selecting a row in an inactive tab must activate that tab and pane.
        app.typeKey("t", modifierFlags: .command)
        let tabs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select tab:'"))
        let twoTabs = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabs.count == 2 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [twoTabs], timeout: 5), .completed)
        let inactive = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Not selected'"), object: first
        )
        XCTAssertEqual(XCTWaiter.wait(for: [inactive], timeout: 5), .completed)
        first.click()
        expectSelected(first)

        // A zoomed sibling must be revealed before it can receive focus.
        app.typeKey("\n", modifierFlags: [.command, .shift])
        second.click()
        expectSelected(second)
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
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select split '")).count, 0)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close split '")).count, 0)
        expand.click()
        let closeSplit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close split 2:'")).firstMatch
        XCTAssertTrue(closeSplit.waitForExistence(timeout: 5))
        closeSplit.click()
        // Closing one pane must leave its sibling alive and restore the tab close action.
        XCTAssertTrue(closeTab.waitForExistence(timeout: 5))
        XCTAssertFalse(collapse.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select split '")).count, 0)
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    @MainActor
    private func expectSelected(_ element: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Selected'"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }
}
