import Foundation
import XCTest
@testable import PhoneBridge

final class IOSMediaDateResolverTests: XCTestCase {
    func testPrefersFirstUsableMetadataDate() throws {
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        let laterCandidate = Date(timeIntervalSince1970: 1_800_000_000)

        let result = IOSMediaDateResolver.resolve(
            candidates: [Date(timeIntervalSince1970: 0), nil, expected, laterCandidate],
            filename: "IMG_20260828_123456.HEIC"
        )

        XCTAssertEqual(result, expected)
    }

    func testFallsBackToCompactFilenameTimestamp() throws {
        let result = try XCTUnwrap(IOSMediaDateResolver.resolve(
            candidates: [nil, nil],
            filename: "IMG_20260828_123456.HEIC"
        ))
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: result
        )

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 28)
        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 34)
        XCTAssertEqual(components.second, 56)
    }

    func testFallsBackToSeparatedFilenameDate() throws {
        let result = try XCTUnwrap(IOSMediaDateResolver.resolve(
            candidates: [],
            filename: "Screenshot 2026-08-28 at 12.34.56.png"
        ))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: result)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 28)
    }

    func testReturnsNilWhenNoDateCanBeRecovered() {
        XCTAssertNil(IOSMediaDateResolver.resolve(candidates: [nil], filename: "IMG_0042.HEIC"))
    }
}
