import XCTest
@testable import PhoneBridge

final class MirroringProcessLifecycleTests: XCTestCase {
    func testIPhoneAirPlayUsesSoftwareDecoderAndJPEGStreamSink() {
        let arguments = IPhoneAirPlayLaunchArguments.make(
            receiverName: "PhoneBridge Test",
            deviceID: "02:50:42:52:49:44",
            streamPort: 54_321,
            quality: .clear,
            peerToPeer: false,
            pin: nil
        )

        XCTAssertTrue(arguments.contains("-avdec"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-s")! + 1], "1920x1080@60")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-fps")! + 1], "30")
        XCTAssertEqual(
            arguments[arguments.firstIndex(of: "-vs")! + 1],
            "jpegenc quality=97 ! tcpclientsink host=127.0.0.1 port=54321"
        )
        XCTAssertFalse(arguments.contains("-p2p"))
    }

    func testIPhoneAirPlayPreservesPeerToPeerPINWithSoftwareDecoder() {
        let arguments = IPhoneAirPlayLaunchArguments.make(
            receiverName: "PhoneBridge Test",
            deviceID: "02:50:42:52:49:44",
            streamPort: 50_001,
            quality: .smooth,
            peerToPeer: true,
            pin: "2468"
        )

        XCTAssertTrue(arguments.contains("-avdec"))
        XCTAssertEqual(Array(arguments.suffix(3)), ["-p2p", "-pin", "2468"])
    }

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
