import XCTest

/// End-to-end flows: create a saved place, capture reminders by text
/// (time-only, both-conditions race, urgent), verify the post-save detail
/// sheet, the list, and the saved-place deletion warning.
final class TapUITests: XCTestCase {
    var app: XCUIApplication!
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // UserDefaults honors command-line overrides: start in text mode so
        // capture tests don't depend on tapping the mode segment.
        app.launchArguments += ["-lastCaptureMode", "text"]
        app.launch()
        dismissSystemAlerts()
    }

    /// Location/notification permission alerts appear on first launch.
    private func dismissSystemAlerts() {
        for _ in 0..<4 {
            let candidates = [
                "Allow While Using App",
                "Keep Only While Using",
                "Allow",
            ]
            var tapped = false
            for label in candidates {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 2) {
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { break }
        }
        app.activate()
    }

    private func goToTab(_ name: String) {
        // The floating tab bar is covered while the keyboard is up — dismiss first.
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.exists && hideKeyboard.isHittable {
            hideKeyboard.tap()
            usleep(400_000)
        }
        app.tabBars.buttons[name].tap()
    }

    private func typeCapture(_ text: String) {
        goToTab("Capture")
        let textSegment = app.buttons["Text"]
        if textSegment.waitForExistence(timeout: 2) { textSegment.tap() }
        let field = app.textFields["captureField"]
        if !field.waitForExistence(timeout: 3) {
            // Multiline TextField can surface as textView
            let tv = app.textViews["captureField"]
            XCTAssertTrue(tv.waitForExistence(timeout: 3), "capture field not found")
            tv.tap()
            tv.typeText(text)
        } else {
            field.tap()
            field.typeText(text)
        }
        app.buttons["captureSubmit"].tap()
    }

    private func dismissDetailSheet() {
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
    }

    // MARK: - Tests (ordered by name: test1, test2, …)

    func test1_createSavedPlace() throws {
        goToTab("Places")
        app.buttons["addPlaceButton"].tap()

        let nameField = app.textFields["Home, Work, Gym…"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Work")

        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5), "map not shown")
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertTrue(save.isEnabled, "Save should enable after name + pin")
        save.tap()

        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 3), "place not in list")
    }

    func test2_timeOnlyCaptureShowsDetailSheet() throws {
        typeCapture("buy milk at 9pm")

        // Post-save detail sheet must open automatically.
        XCTAssertTrue(app.navigationBars["Edit"].waitForExistence(timeout: 4), "detail sheet did not open after capture")
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS[c] 'buy milk'")).firstMatch.exists
                      || app.textFields.containing(NSPredicate(format: "value CONTAINS[c] 'buy milk'")).firstMatch.exists,
                      "content not shown on detail page")
        // Time row present, location empty with add affordance.
        XCTAssertTrue(app.staticTexts["Add location"].exists, "should offer adding second condition")
        dismissDetailSheet()

        goToTab("Reminders")
        XCTAssertTrue(app.staticTexts["buy milk"].waitForExistence(timeout: 3), "reminder missing from list")
    }

    func test3_bothConditionsCreateRaceReminder() throws {
        typeCapture("call dad at 6pm when I leave Work")

        XCTAssertTrue(app.navigationBars["Edit"].waitForExistence(timeout: 4))
        // Race banner on the edit page proves both conditions landed.
        let racePredicate = NSPredicate(format: "label CONTAINS[c] 'Both conditions are set'")
        XCTAssertTrue(app.staticTexts.containing(racePredicate).firstMatch.waitForExistence(timeout: 2),
                      "race banner missing — one condition was dropped")
        dismissDetailSheet()

        goToTab("Reminders")
        XCTAssertTrue(app.staticTexts["call dad"].waitForExistence(timeout: 3))
        let raceRow = NSPredicate(format: "label CONTAINS[c] 'pings you'")
        XCTAssertTrue(app.staticTexts.containing(raceRow).firstMatch.exists, "race caption missing in list")
    }

    func test4_urgentDoubleBang() throws {
        typeCapture("pay rent tomorrow at noon!!")

        XCTAssertTrue(app.navigationBars["Edit"].waitForExistence(timeout: 4))
        let urgentToggle = app.switches["Urgent"].firstMatch
        XCTAssertTrue(urgentToggle.waitForExistence(timeout: 2))
        XCTAssertEqual(urgentToggle.value as? String, "1", "!! did not set urgent")
        dismissDetailSheet()
    }

    func test8_voiceOrbDiagnostic() throws {
        func snap(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }

        goToTab("Capture")
        app.buttons["Voice"].tap()
        sleep(1)
        snap("v1-voice-mode")

        let orb = app.buttons["Start recording"]
        XCTAssertTrue(orb.waitForExistence(timeout: 3), "voice orb button not found/tappable")
        orb.tap()
        sleep(2)

        // Speech + mic permission alerts on first use.
        for _ in 0..<3 {
            var tapped = false
            for label in ["OK", "Allow", "Allow While Using App"] {
                let b = springboard.buttons[label]
                if b.waitForExistence(timeout: 2) { b.tap(); tapped = true; break }
            }
            if !tapped { break }
        }
        app.activate()
        sleep(2)
        snap("v2-after-tap")

        let recording = app.buttons["Stop recording"].exists
        let errorShown = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'permission' OR label CONTAINS[c] 'not available' OR label CONTAINS[c] 'Could not'")
        ).firstMatch
        print("VOICE-DIAG recording=\(recording) errorVisible=\(errorShown.exists) errorLabel=\(errorShown.exists ? errorShown.label : "none")")
        snap("v3-final")
    }

    func test9_screenshotTour() throws {
        func snap(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }

        // Capture screen with live parse chips visible.
        goToTab("Capture")
        let field = app.textFields["captureField"].exists
            ? app.textFields["captureField"] : app.textViews["captureField"]
        field.tap()
        field.typeText("call dad at 6pm when I leave Work")
        sleep(1)
        snap("1-capture-chips")

        app.buttons["captureSubmit"].tap()
        if app.navigationBars["Edit"].waitForExistence(timeout: 4) {
            snap("2-detail-map")
            dismissDetailSheet()
        }

        goToTab("Reminders")
        sleep(1)
        snap("3-list")

        goToTab("Places")
        sleep(1)
        snap("4-places")
    }

    func test5_deletePlaceWarnsAboutAffectedReminders() throws {
        goToTab("Places")
        let workCell = app.cells.containing(.staticText, identifier: "Work").firstMatch
        XCTAssertTrue(workCell.waitForExistence(timeout: 3))
        workCell.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "swipe delete button not shown")
        delete.tap()

        // Warning must mention affected reminder count before confirming.
        let warning = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'affects'")
        ).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 3), "no deletion warning with affected count")
        // iOS 26 confirmation dialogs expose no Cancel button to the a11y tree;
        // dismissing is done by tapping outside the sheet.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 3), "dismissing should keep the place")
    }
}
