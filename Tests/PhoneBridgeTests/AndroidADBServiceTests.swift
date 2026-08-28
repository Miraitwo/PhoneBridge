import XCTest
@testable import PhoneBridge

final class AndroidADBServiceTests: XCTestCase {
    func testCreatesAndroidStudioCompatibleQRPairingPayload() {
        let request = AndroidADBService.makeQRPairingRequest()

        XCTAssertTrue(request.serviceName.hasPrefix("studio-"))
        XCTAssertEqual(request.serviceName.count, 17)
        XCTAssertEqual(request.password.count, 12)
        XCTAssertEqual(
            request.payload,
            "WIFI:T:ADB;S:\(request.serviceName);P:\(request.password);;"
        )
    }

    func testParsesADBMDNSPairingAndConnectionServices() {
        let output = """
        List of discovered mdns services
        studio-AbCd1234-x	_adb-tls-pairing._tcp.	192.168.1.86:37313
        adb-939AX05XBZ-vWgJpq	_adb-tls-connect._tcp.	192.168.1.86:39149

        """

        let services = AndroidADBService.parseMDNSServices(output)

        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0].name, "studio-AbCd1234-x")
        XCTAssertEqual(services[0].kind, .pairing)
        XCTAssertEqual(services[0].endpoint, "192.168.1.86:37313")
        XCTAssertEqual(services[1].name, "adb-939AX05XBZ-vWgJpq")
        XCTAssertEqual(services[1].kind, .connection)
        XCTAssertEqual(services[1].endpoint, "192.168.1.86:39149")
    }

    func testParsesPairingGUID() {
        let output = "Successfully paired to 192.168.1.86:41915 [guid=adb-939AX05XBZ-vWgJpq]"

        XCTAssertEqual(
            AndroidADBService.pairingGUID(from: output),
            "adb-939AX05XBZ-vWgJpq"
        )
    }

    func testParsesActiveUSBAdvertisedPairingService() {
        let output = """
        Active clients:
          Advertiser: serviceFullName=studio-hluJAK0IUX._adb-tls-pairing._tcp, net=null
        Logs:
          Adding service name: studio-hluJAK0IUX, type: _adb-tls-pairing._tcp, subtypes: , hostAddresses: , hostname: null, port: 46113, network: null
        """

        XCTAssertEqual(
            AndroidADBService.advertisedServicePort(
                from: output,
                name: "studio-hluJAK0IUX",
                kind: .pairing
            ),
            46113
        )
    }

    func testIgnoresRemovedUSBAdvertisedPairingService() {
        let output = """
        Active clients:
        Logs:
          Adding service name: studio-old, type: _adb-tls-pairing._tcp, subtypes: , hostAddresses: , hostname: null, port: 40717, network: null
        """

        XCTAssertNil(
            AndroidADBService.advertisedServicePort(
                from: output,
                name: "studio-old",
                kind: .pairing
            )
        )
    }

    func testParsesWirelessIPv4() {
        let output = """
        47: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
            inet 172.23.160.75/22 brd 172.23.163.255 scope global dynamic wlan0
        """

        XCTAssertEqual(AndroidADBService.wirelessIPv4(from: output), "172.23.160.75")
    }

    func testFindsExternallyListeningHighPortsAsWirelessADBCandidates() {
        let output = """
        Cannot open netlink socket: Permission denied
        State Recv-Q Send-Q Local Address:Port Peer Address:Port
        LISTEN 0 0 127.0.0.1:45791 0.0.0.0:*
        LISTEN 0 0 *:8080 *:*
        LISTEN 0 0 *:40289 *:*
        LISTEN 0 0 *:6791 *:*
        """

        XCTAssertEqual(AndroidADBService.candidateWirelessADBPorts(from: output), [40289])
    }

    func testADBConnectOutputRequiresActualSuccessText() {
        XCTAssertTrue(AndroidADBService.isSuccessfulADBConnectOutput("connected to 172.23.160.75:40289"))
        XCTAssertTrue(AndroidADBService.isSuccessfulADBConnectOutput("already connected to 172.23.160.75:40289"))
        XCTAssertFalse(AndroidADBService.isSuccessfulADBConnectOutput("failed to connect to 172.23.160.75:40289"))
    }

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

    func testDeduplicatesUSBAndWirelessTransportsForSamePhysicalDevice() {
        let output = """
        List of devices attached
        ABC123 device usb:1-2 product:akita model:Pixel_8a device:akita transport_id:1
        192.168.1.20:37123 device product:akita model:Pixel_8a device:akita transport_id:2

        """

        let transports = AndroidADBService.parseDeviceTransports(output)
        let devices = AndroidADBService.deduplicatedDevices(
            transports: transports,
            physicalSerials: [
                "ABC123": "ABC123",
                "192.168.1.20:37123": "ABC123"
            ]
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "ABC123", "同一台手机应优先保留 USB 通道")
    }

    func testKeepsDifferentPhysicalAndroidDevices() {
        let output = """
        List of devices attached
        USB-A device usb:1-2 product:akita model:Pixel_8a device:akita transport_id:1
        192.168.1.21:37123 device product:husky model:Pixel_8_Pro device:husky transport_id:2

        """

        let transports = AndroidADBService.parseDeviceTransports(output)
        let devices = AndroidADBService.deduplicatedDevices(
            transports: transports,
            physicalSerials: [
                "USB-A": "PHYSICAL-A",
                "192.168.1.21:37123": "PHYSICAL-B"
            ]
        )

        XCTAssertEqual(devices.map(\.id), ["USB-A", "192.168.1.21:37123"])
    }

    func testDoesNotGuessDuplicateDevicesWhenPhysicalSerialIsUnavailable() {
        let output = """
        List of devices attached
        USB-A device usb:1-2 product:akita model:Pixel_8a device:akita transport_id:1
        192.168.1.20:37123 device product:akita model:Pixel_8a device:akita transport_id:2

        """

        let transports = AndroidADBService.parseDeviceTransports(output)
        let devices = AndroidADBService.deduplicatedDevices(
            transports: transports,
            physicalSerials: [:]
        )

        XCTAssertEqual(devices.map(\.id), ["USB-A", "192.168.1.20:37123"])
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
