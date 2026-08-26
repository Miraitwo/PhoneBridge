import Foundation
import XCTest
@testable import PhoneBridge

final class DragCodecTests: XCTestCase {
    func testRoundTripsRemoteEntriesThroughTextPayload() throws {
        let entry = RemoteEntry(
            id: "ios-1/file-1",
            deviceID: "ios-1",
            platform: .ios,
            name: "IMG_0001.HEIC",
            remotePath: "/IMG_0001.HEIC",
            kind: .image,
            size: 1_024,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let payload = RemoteDragCodec.payload(for: [entry])
        let decoded = try XCTUnwrap(RemoteDragCodec.entries(from: payload))

        XCTAssertEqual(decoded, [entry])
    }

    func testRejectsUnrelatedPlainText() {
        XCTAssertNil(RemoteDragCodec.entries(from: "hello"))
        XCTAssertNil(RemoteDragCodec.entries(from: RemoteDragCodec.payloadPrefix))
    }
}
