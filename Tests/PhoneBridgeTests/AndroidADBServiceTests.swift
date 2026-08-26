import XCTest
@testable import PhoneBridge

final class AndroidADBServiceTests: XCTestCase {
    func testParsesConnectedAndroidDevicesOnly() {
        let output = """
        List of devices attached
        emulator-5554 device product:sdk_gphone model:Pixel_8 device:emu transport_id:1
        offline-123 offline product:test model:Ignored device:test transport_id:2

        """

        let devices = AndroidADBService.parseDevices(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "emulator-5554")
        XCTAssertEqual(devices[0].name, "Pixel 8")
    }

    func testParsesDirectoriesAndMediaButFiltersOtherFiles() {
        let output = """
        directory|4096|1700000000|/sdcard/DCIM/Camera
        regular file|1024|1700000001|/sdcard/DCIM/IMG 001.HEIC
        regular file|2048|1700000002|/sdcard/DCIM/VID_001.MP4
        regular file|99|1700000003|/sdcard/DCIM/notes.txt
        """

        let entries = AndroidADBService.parseDirectoryListing(output, deviceID: "phone-1")

        XCTAssertEqual(entries.map(\.name), ["Camera", "IMG 001.HEIC", "VID_001.MP4"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .image, .video])
    }

    func testJPEGStreamParserHandlesLogsAndSplitFrames() {
        var parser = JPEGStreamParser()
        let firstPart = Data("UxPlay ready\n".utf8) + Data([0xff, 0xd8, 0x01])
        let secondPart = Data([0x02, 0xff, 0xd9, 0xff, 0xd8, 0x03, 0xff, 0xd9])

        XCTAssertTrue(parser.append(firstPart).isEmpty)
        XCTAssertEqual(
            parser.append(secondPart),
            [
                Data([0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9]),
                Data([0xff, 0xd8, 0x03, 0xff, 0xd9])
            ]
        )
    }
}
