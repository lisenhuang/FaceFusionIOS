//
//  FaceFusionUITests.swift
//  FaceFusionUITests
//
//  Launch smoke tests, and a screenshot of the studio in every orientation.
//
//  The interesting claim this app makes about its interface is that one
//  workspace holds together in three different shapes — a control column beside
//  the canvas, a canvas and column side by side, and a canvas with the controls
//  scrolling underneath — chosen by size class and changing mid-session on a
//  rotation. That is not something a unit test can look at, and it is exactly
//  the kind of thing that breaks quietly: a clipped action bar, or a control
//  pushed under the home indicator, still compiles and still passes every other
//  test.
//
//  So these rotate the device and attach what they find. The assertions are
//  deliberately weak — that the app survived and the workspace is on screen —
//  because the value here is the attachments, which a person looks at.
//

import XCTest

final class FaceFusionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    override func tearDown() {
        // Leave the device the way it was found, or the next test in the run
        // inherits an orientation it never asked for.
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Walks the orientations and keeps a screenshot of each.
    @MainActor
    func testStudioInEveryOrientation() {
        let app = XCUIApplication()
        app.launch()

        let orientations: [(name: String, value: UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape-left", .landscapeLeft),
            ("landscape-right", .landscapeRight),
        ]

        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation.value
            // A rotation is animated, and a screenshot taken during it catches
            // the interpolation rather than the layout.
            Thread.sleep(forTimeInterval: 2)

            XCTAssertEqual(app.state, .runningForeground,
                           "the app should survive rotating to \(orientation.name)")

            // The assertion that actually means something. A screenshot of a
            // rotated simulator is easy to misread — the image buffer can be
            // landscape while the pixels inside it are not — so the check is on
            // the app's own frame, which is the layout's real input.
            let frame = app.frame
            let isLandscape = orientation.value.isLandscape
            XCTAssertEqual(frame.width > frame.height, isLandscape,
                           "\(orientation.name): app frame is \(frame.size), which is not \(isLandscape ? "landscape" : "portrait")")

            // Whole-screen rather than app-relative: this is the one that
            // reliably comes back oriented the way a person would see it.
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "studio-\(orientation.name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// Settings, and the theme actually changing the app behind it.
    ///
    /// The theme is the one setting whose whole job is to be visible, and the
    /// way it fails is silent: an `@AppStorage` read outside a `body`, or a
    /// `preferredColorScheme` applied below the sheet rather than above it,
    /// leaves the picker moving and nothing else. So this picks Dark and keeps
    /// a screenshot of the result rather than trusting that the binding is wired.
    @MainActor
    func testThemePickerAppliesImmediately() {
        let app = XCUIApplication()
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "the studio should offer Settings")
        settings.tap()

        let dark = app.buttons["Dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 10), "Settings should offer a Dark theme option")

        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "settings-before-dark"
        before.lifetime = .keepAlways
        add(before)

        dark.tap()
        Thread.sleep(forTimeInterval: 1.5)

        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "settings-after-dark"
        after.lifetime = .keepAlways
        add(after)

        XCTAssertEqual(app.state, .runningForeground)

        // Back out to the studio, which must have taken the theme with it.
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        Thread.sleep(forTimeInterval: 1.5)

        let studio = XCTAttachment(screenshot: app.screenshot())
        studio.name = "studio-dark-theme"
        studio.lifetime = .keepAlways
        add(studio)
    }

    /// The one thing here worth asserting rather than eyeballing: the export
    /// button exists and is disabled before there is anything to export. It is
    /// the control that costs the most to press by mistake.
    @MainActor
    func testExportIsUnavailableUntilThereIsSomethingToExport() {
        let app = XCUIApplication()
        app.launch()

        let export = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'Export'"))
            .firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 30),
                      "the studio should offer an export button")
        XCTAssertFalse(export.isEnabled,
                       "export should be disabled with no source face and no target")
    }
}
