import XCTest

/// End-to-end flows against demo mode (simulated probes, accelerated time). No account needed.
final class OpenMEATUITests: XCTestCase {
    private var app: XCUIApplication!

    /// chickenFast: one RFX probe "Chicken" (RFX-CHICKEN#1) + ambient (#2).
    private let tipKey = "RFX-CHICKEN#1"

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchDemo(scenario: String = "chickenFast", timeScale: Int = 120, reset: Bool = true) {
        app.launchArguments = [
            "-OM_MOCK", "1", "-OM_RESET", reset ? "1" : "0", "-OM_NO_ANIMATIONS", "1",
            "-OM_SCENARIO", scenario, "-OM_TIME_SCALE", "\(timeScale)", "-OM_POLL", "0.5",
        ]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func startCook(title: String = "Sunday chicken") {
        let titleField = element(AccessibilityID.StartCook.title)
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText(title)
        let start = app.buttons[AccessibilityID.StartCook.start]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        wait(for: start, "isEnabled == true", timeout: 10)
        start.tap()
        XCTAssertTrue(element(AccessibilityID.Live.probeCard(tipKey)).waitForExistence(timeout: 10))
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) never matched \(predicate)", file: file, line: line)
    }

    private func scrollIntoView(_ element: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "\(element) not reachable by scrolling")
    }

    // MARK: Tests

    func testLoginScreenOffersDemoMode() {
        app.launchArguments = ["-OM_RESET", "1", "-OM_NO_ANIMATIONS", "1"]
        app.launch()
        XCTAssertTrue(element(AccessibilityID.Login.email).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[AccessibilityID.Login.signIn].isEnabled)
        app.buttons[AccessibilityID.Login.demo].tap()
        XCTAssertTrue(element(AccessibilityID.StartCook.title).waitForExistence(timeout: 10))
    }

    func testStartCookShowsLiveTemperatures() {
        launchDemo()
        startCook()
        let temp = element(AccessibilityID.Live.probeTemp(tipKey))
        XCTAssertTrue(temp.waitForExistence(timeout: 10))
        wait(for: temp, "label CONTAINS '°F'", timeout: 10)
        XCTAssertTrue(element(AccessibilityID.Live.chart).exists)
        // Freshness is always shown: "Updated <time> · now / x minutes ago".
        let updated = app.descendants(matching: .any).matching(identifier: AccessibilityID.Live.lastUpdated).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 10))
        wait(for: updated, "label BEGINSWITH 'Updated'", timeout: 10)
    }

    func testSetTargetProducesETA() {
        launchDemo(timeScale: 600)
        startCook()
        app.buttons[AccessibilityID.Live.targetButton(tipKey)].tap()
        let save = app.buttons[AccessibilityID.Target.save]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let preset = app.buttons[AccessibilityID.Target.preset("Poultry/Breast")]
        scrollIntoView(preset)
        preset.tap()
        save.tap()

        XCTAssertTrue(app.buttons[AccessibilityID.Live.targetButton(tipKey)].label.contains("160°F"))
        // At 600× the estimator warms up (10 simulated minutes) in about a second.
        let eta = element(AccessibilityID.Live.eta(tipKey))
        wait(for: eta, "label BEGINSWITH '~' OR label == 'Done'", timeout: 30)
    }

    func testQuickNoteAppearsInNotes() {
        launchDemo()
        startCook()
        let wrapped = app.buttons[AccessibilityID.Notes.quick("Wrapped")]
        XCTAssertTrue(wrapped.waitForExistence(timeout: 5))
        wrapped.tap()
        XCTAssertTrue(element(AccessibilityID.Notes.list).staticTexts["Wrapped"].waitForExistence(timeout: 5))
    }

    func testFreeTextNote() {
        launchDemo()
        startCook()
        app.buttons[AccessibilityID.Notes.addButton].tap()
        // Alert text fields don't reliably expose custom identifiers.
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Added cherry wood")
        app.alerts.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(element(AccessibilityID.Notes.list).staticTexts["Added cherry wood"].waitForExistence(timeout: 5))
    }

    func testLegendTogglesSeries() {
        launchDemo()
        startCook()
        let chip = app.buttons[AccessibilityID.Live.legendChip("RFX-CHICKEN#2")]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(chip.value as? String, "shown")
        chip.tap()
        XCTAssertEqual(chip.value as? String, "hidden")
    }

    func testEndedCookAppearsInHistory() {
        launchDemo()
        startCook(title: "History test")
        app.buttons[AccessibilityID.Live.endCook].tap()
        let alert = app.alerts["End this cook?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Keep Cooking"].exists)
        alert.buttons["End & Save"].firstMatch.tap()
        XCTAssertTrue(element(AccessibilityID.StartCook.title).waitForExistence(timeout: 10))

        app.tabBars.buttons["History"].tap()
        let row = element(AccessibilityID.History.row("History test"))
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(AccessibilityID.History.detailChart).waitForExistence(timeout: 10))
    }

    func testCancellingEndKeepsCooking() {
        launchDemo()
        startCook()
        app.buttons[AccessibilityID.Live.endCook].tap()
        let alert = app.alerts["End this cook?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Keep Cooking"].firstMatch.tap()
        XCTAssertTrue(element(AccessibilityID.Live.probeCard(tipKey)).waitForExistence(timeout: 5))
    }

    func testChannelRoleAndNameAreRemembered() {
        launchDemo()
        let ambientKey = "RFX-CHICKEN#2"
        let role = app.segmentedControls[AccessibilityID.StartCook.role(ambientKey)]
        XCTAssertTrue(role.waitForExistence(timeout: 10))
        XCTAssertTrue(role.buttons["Ambient"].isSelected)
        role.buttons["Meat"].tap()
        XCTAssertTrue(role.buttons["Meat"].isSelected)

        app.buttons[AccessibilityID.StartCook.rename(ambientKey)].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("Second bird")
        app.alerts.buttons["Save"].firstMatch.tap()
        wait(for: app.buttons[AccessibilityID.StartCook.rename(ambientKey)], "label CONTAINS 'Second bird'", timeout: 5)

        // Relaunch without resetting: choices persist.
        app.terminate()
        launchDemo(reset: false)
        let roleAgain = app.segmentedControls[AccessibilityID.StartCook.role(ambientKey)]
        XCTAssertTrue(roleAgain.waitForExistence(timeout: 10))
        XCTAssertTrue(roleAgain.buttons["Meat"].isSelected)
        wait(for: app.buttons[AccessibilityID.StartCook.rename(ambientKey)], "label CONTAINS 'Second bird'", timeout: 5)
    }

    func testChartReadoutShowsValuesAndAxisToggle() {
        launchDemo()
        startCook()
        let value = element(AccessibilityID.Live.readoutValue(tipKey))
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        wait(for: value, "label CONTAINS '°F'", timeout: 10)
        let axis = app.segmentedControls[AccessibilityID.Live.chartAxisMode]
        XCTAssertTrue(axis.exists)
        axis.buttons["Elapsed"].tap()
        XCTAssertTrue(axis.buttons["Elapsed"].isSelected)
    }

    func testAlmostDoneLeadTimeDefaultsToFiveAndIsAdjustable() {
        launchDemo()
        app.tabBars.buttons["Settings"].tap()
        let value = element(AccessibilityID.Settings.leadTimeValue)
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertTrue(value.label.contains("5 min"), value.label)
        // Stepper buttons are [decrement, increment].
        let increment = app.steppers[AccessibilityID.Settings.leadTime].buttons.allElementsBoundByIndex.last
        XCTAssertNotNil(increment)
        increment?.tap()
        wait(for: element(AccessibilityID.Settings.leadTimeValue), "label CONTAINS '6 min'", timeout: 5)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
