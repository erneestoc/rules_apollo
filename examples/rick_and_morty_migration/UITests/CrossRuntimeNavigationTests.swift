import XCTest

/// Episodes (Apollo iOS 2.4.0) links into the Characters detail screen (Apollo iOS 1.15.2)
/// through CharacterUI. Both runtimes fetch from the live API in the same app.
final class CrossRuntimeNavigationTests: XCTestCase {
  @MainActor
  func testEpisodeCastOpensCharacterDetail() {
    let app = XCUIApplication()
    app.launch()

    // Characters tab: 1.15.2.
    XCTAssertTrue(app.staticTexts["Rick Sanchez"].waitForExistence(timeout: 30))

    // Episodes tab: 2.4.0.
    app.tabBars.buttons["Episodes"].tap()
    let pilot = app.staticTexts["Pilot"]
    XCTAssertTrue(pilot.waitForExistence(timeout: 30))
    pilot.tap()

    // The episode's cast, from the 2.4.0 CharacterCard fragment.
    let rick = app.staticTexts["Rick Sanchez"]
    XCTAssertTrue(rick.waitForExistence(timeout: 30))
    rick.tap()

    // The 1.15.2 Characters detail screen, fetched by the 1.15.2 client.
    XCTAssertTrue(app.staticTexts["Gender"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["S01E01 · Pilot"].waitForExistence(timeout: 30))
  }
}
