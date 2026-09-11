import Foundation
import XCTest
@testable import PhoneBridge

final class FirstLaunchGuideStateTests: XCTestCase {
    func testGuideIsPresentedOnlyOnce() throws {
        let suiteName = "PhoneBridgeTests.FirstLaunchGuide.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(FirstLaunchGuideState.shouldPresent(defaults: defaults))

        FirstLaunchGuideState.markPresented(defaults: defaults)

        XCTAssertFalse(FirstLaunchGuideState.shouldPresent(defaults: defaults))
    }

    func testUnrelatedPreferencesDoNotSuppressGuide() throws {
        let suiteName = "PhoneBridgeTests.FirstLaunchGuide.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "PhoneBridge.someOtherPreference")

        XCTAssertTrue(FirstLaunchGuideState.shouldPresent(defaults: defaults))
    }
}
