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

    private func launchDemo(scenario: String = "chickenFast", timeScale: Int = 120) {
        app.launchArguments = [
            "-OM_MOCK", "1", "-OM_RESET", "1", "-OM_NO_ANIMATIONS", "1",
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
        let confirm = app.buttons.matching(identifier: AccessibilityID.Live.confirmEnd).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element(AccessibilityID.StartCook.title).waitForExistence(timeout: 10))

        app.tabBars.buttons["History"].tap()
        let row = element(AccessibilityID.History.row("History test"))
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(AccessibilityID.History.detailChart).waitForExistence(timeout: 10))
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
