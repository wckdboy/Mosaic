import XCTest

// Each launch builds a separate, deterministic library. Assertions describe user
// journeys and semantics; no test needs a real Photos grant or cloud credentials.
@MainActor final class MosaicUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Manual simulator review or a failed orientation test must not leak
        // landscape into later tests. Set this before each app launch.
        XCUIDevice.shared.orientation = .portrait
    }
    private func launch(
        appearance: String = "light", direction: String = "vertical", largeText: Bool = false,
        video: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-appearance", appearance, "-galleryDirection", direction,
            "-mosaicGrouping", "Name", "-visualAnalysis", "NO", "-gridColumns",
            "3", "-resumePlayback", "NO",
        ]
        if video { app.launchArguments.append("--ui-testing-video") }
        if largeText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(app.buttons["media-fixture:0"].waitForExistence(timeout: 15))
    }
    private func capture(_ name: String) {
        // Capture the device: application-cropped screenshots can retain stale
        // portrait bounds immediately after a simulator orientation change.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testNavigationAndDiscoveryRoundTrip() throws {
        launch()
        XCTAssertEqual(app.tabBars.buttons.count, 2)
        app.buttons["media-fixture:0"].tap()
        XCTAssertTrue(app.staticTexts["viewer.filename"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["viewer.filename"].value as? String, "Study_001.jpg")
        app.buttons["Find similar"].tap()
        XCTAssertTrue(app.buttons["mosaic.focus"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertEqual(app.staticTexts["viewer.filename"].value as? String, "Study_001.jpg")
        app.buttons["Close"].tap()
        app.buttons["Mosaic view"].tap()
        let search = app.textFields["mosaic.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Study_015\n")
        XCTAssertTrue(
            app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Study_015")).firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells.count, 1)
        capture("Filtered mosaic")
        app.buttons["Clear search"].tap()
        app.buttons["Gallery view"].tap()
        XCTAssertTrue(app.buttons["media-fixture:0"].waitForExistence(timeout: 5))
    }
    func testCanvasTapExploresAndBackReturnsToOverview() throws {
        launch()
        app.buttons["Mosaic view"].tap()
        XCTAssertTrue(app.textFields["mosaic.search"].waitForExistence(timeout: 5))
        let canvas = app.collectionViews["mosaic.canvas"]
        // The canvas is two-dimensional: both axes pan.
        canvas.swipeLeft()
        canvas.swipeUp()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["mosaic.focus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Match by Similar"].exists)
        XCTAssertGreaterThan(app.cells.count, 1)
        capture("Focused discovery")
        app.buttons["Match by Name"].tap()
        XCTAssertTrue(app.buttons["Match by Name"].isSelected)
        app.buttons["Back to Mosaic"].tap()
        XCTAssertTrue(app.textFields["mosaic.search"].waitForExistence(timeout: 5))
    }
    func testOrganizationPreviewApplyUndoAndPhysicalExclusion() throws {
        launch()
        app.buttons["library.options"].tap()
        app.buttons["Auto organize"].tap()
        let apply = app.buttons["Organize 60 items"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        capture("Batch preview")
        apply.tap()
        XCTAssertTrue(app.staticTexts["A little more organized."].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Organize 60 items"].waitForExistence(timeout: 5))
        app.buttons["Original files"].tap()
        let move = app.buttons["Review 0 file moves"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        XCTAssertFalse(move.isEnabled)
        app.buttons["Close"].tap()
        app.buttons["media-fixture:0"].tap()
        XCTAssertEqual(app.staticTexts["viewer.filename"].value as? String, "Study_001.jpg")
    }
    func testHorizontalGallerySurvivesRepeatedViewerTransitions() {
        launch(direction: "horizontal")
        for iteration in 0..<6 {
            app.buttons["media-fixture:0"].tap()
            XCTAssertTrue(app.buttons["Find similar"].waitForExistence(timeout: 5))
            app.swipeLeft()
            XCTAssertEqual(app.staticTexts["viewer.filename"].value as? String, "Study_002.jpg")
            // Alternate the two ways out: the Close button and the swipe-down gesture.
            if iteration.isMultiple(of: 2) {
                app.buttons["Close"].tap()
            } else {
                app.swipeDown()
            }
            XCTAssertTrue(app.buttons["library.options"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["library.options"].isHittable)
    }
    // The viewer pages horizontally like Photos; up opens details, down closes.
    func testViewerSwipesPageShowDetailsAndDismiss() {
        launch()
        app.buttons["media-fixture:0"].tap()
        XCTAssertTrue(app.buttons["Find similar"].waitForExistence(timeout: 5))
        app.swipeLeft()
        XCTAssertEqual(app.staticTexts["viewer.filename"].value as? String, "Study_002.jpg")
        app.swipeRight()
        XCTAssertEqual(app.staticTexts["viewer.filename"].value as? String, "Study_001.jpg")
        app.swipeUp()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertEqual(app.staticTexts["viewer.filename"].value as? String, "Study_001.jpg")
        app.swipeDown()
        XCTAssertTrue(app.buttons["library.options"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["viewer.filename"].exists)
    }
    func testVideoTransportControlsAndChromeToggle() throws {
        launch(video: true)
        app.buttons["media-fixture:video"].tap()
        let playPause = app.buttons["viewer.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        // Autoplay starts the clip; pausing keeps the floating controls on screen.
        if playPause.label == "Pause" { playPause.tap() }
        XCTAssertEqual(playPause.label, "Play")
        XCTAssertTrue(app.descendants(matching: .any)["viewer.scrubber"].exists)
        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Back 10 seconds"].isHittable)
        XCTAssertTrue(app.buttons["Forward 10 seconds"].isHittable)
        capture("Video controls")
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait])
        // A tap on the picture hides all chrome; a second tap restores it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["Close"].waitForNonExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 3))
        playPause.tap()
        XCTAssertEqual(app.buttons["viewer.playPause"].label, "Pause")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["library.options"].waitForExistence(timeout: 5))
    }
    func testAccessibilityLightGalleryAndViewer() throws {
        launch()
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait])
        app.buttons["media-fixture:0"].tap()
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait])
    }
    func testAccessibilityDarkCanvas() throws {
        launch(appearance: "dark")
        app.buttons["Mosaic view"].tap()
        XCTAssertTrue(app.textFields["mosaic.search"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait])
        capture("Dark canvas")
    }
    func testLandscapeCanvasKeepsMediaAndControlsReachable() {
        launch(largeText: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["Mosaic view"].tap()
        XCTAssertTrue(app.textFields["mosaic.search"].waitForExistence(timeout: 5))
        // A toolbar must not consume nearly the whole canvas at large text sizes.
        XCTAssertGreaterThan(app.collectionViews.firstMatch.frame.height, 180)
        app.buttons["Canvas options"].tap()
        app.buttons["Zoom"].tap()
        app.buttons["Zoom out"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        capture("Landscape XXXL canvas")
        // A tile explores its neighborhood first; the reference opens full screen.
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["mosaic.focus"].waitForExistence(timeout: 5))
        app.buttons["mosaic.focus"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close"].isHittable)
        capture("Landscape XXXL viewer")
        app.buttons["Close"].tap()
    }
    func testLargestTextKeepsPrimaryActionsReachable() throws {
        launch(largeText: true)
        app.buttons["library.options"].tap()
        app.buttons["Auto organize"].tap()
        XCTAssertTrue(app.buttons["Organize 60 items"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Organize 60 items"].isHittable)
        XCTAssertTrue(app.buttons["Close"].isHittable)
        app.buttons["Insert field"].tap()
        XCTAssertTrue(app.buttons["{original}"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["{original}"].isHittable)
        app.buttons["{date}"].tap()
        capture("Accessibility XXXL organization")
        try app.performAccessibilityAudit(for: [.textClipped, .sufficientElementDescription]) {
            [self] issue in
            // iOS 27 reports the native Menu's fully visible label as clipped at
            // XXXL. Verified against a screenshot and hierarchy (234×63pt label
            // inside a 400×93pt button). Keep this exception specific: the label
            // must remain hittable and completely above the pinned action area.
            // Also observed on iOS 26.1 with the label fully above the action bar.
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
                issue.auditType == .textClipped, let element = issue.element,
                element.label == "Insert field"
            else { return false }
            let frame = element.frame
            return app.buttons["Insert field"].isHittable && frame.width > 0 && frame.height > 0
                && app.windows.firstMatch.frame.contains(frame)
                && frame.maxY < app.buttons["Organize 60 items"].frame.minY
        }
    }
}
