import XCTest
@testable import PhoneBridge

final class MirroringProcessLifecycleTests: XCTestCase {
    func testRecognizesUxPlayVideoDisconnectMessages() {
        XCTAssertTrue(MirroringProcessLifecycle.uxPlayOutputIndicatesStreamEnded([
            "raop_rtp_mirror tcp socket was closed by client"
        ]))
        XCTAssertTrue(MirroringProcessLifecycle.uxPlayOutputIndicatesStreamEnded([
            "**************************on_video_stop"
        ]))
        XCTAssertFalse(MirroringProcessLifecycle.uxPlayOutputIndicatesStreamEnded([
            "Initialized server socket(s)"
        ]))
    }

    func testFindsOnlyExactBundledUxPlayProcesses() {
        let bundledPath = "/Applications/PhoneBridge.app/Contents/Resources/uxplay"
        let output = """
            101 /Applications/PhoneBridge.app/Contents/Resources/uxplay -n PhoneBridge
            102 /opt/homebrew/bin/uxplay -n PhoneBridge
            103 /Applications/PhoneBridge.app/Contents/Resources/uxplay-helper
            104 /Applications/PhoneBridge.app/Contents/Resources/uxplay
        """

        XCTAssertEqual(
            MirroringProcessLifecycle.processIDs(
                inPSOutput: output,
                executablePath: bundledPath
            ),
            [101, 104]
        )
    }
}
