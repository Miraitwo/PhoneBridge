import Foundation
import XCTest
@testable import PhoneBridge

final class AppUpdateCheckerTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testReleaseVersionComparisonHandlesVPrefixAndMissingComponents() {
        XCTAssertTrue(ReleaseVersion("v0.17.0")! > ReleaseVersion("0.16.1")!)
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0"))
        XCTAssertTrue(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!)
        XCTAssertNil(ReleaseVersion("release-next"))
    }

    func testUpdatePolicyOnlyAcceptsNewerValidRelease() {
        XCTAssertTrue(AppUpdatePolicy.isNewerRelease(tagName: "v0.16.2", than: "0.16.1"))
        XCTAssertFalse(AppUpdatePolicy.isNewerRelease(tagName: "v0.16.1", than: "0.16.1"))
        XCTAssertFalse(AppUpdatePolicy.isNewerRelease(tagName: "v0.15.9", than: "0.16.1"))
        XCTAssertFalse(AppUpdatePolicy.isNewerRelease(tagName: "nightly", than: "0.16.1"))
    }

    func testAutomaticCheckPolicyUsesTwentyFourHourInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(AppUpdatePolicy.shouldCheckAutomatically(lastSuccessfulCheck: nil, now: now))
        XCTAssertFalse(AppUpdatePolicy.shouldCheckAutomatically(
            lastSuccessfulCheck: now.addingTimeInterval(-23 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(AppUpdatePolicy.shouldCheckAutomatically(
            lastSuccessfulCheck: now.addingTimeInterval(-24 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(AppUpdatePolicy.shouldCheckAutomatically(
            lastSuccessfulCheck: now.addingTimeInterval(60),
            now: now
        ))
    }

    func testDecodesGitHubLatestReleasePayload() throws {
        let payload = #"""
        {
          "tag_name": "v0.16.2",
          "name": "PhoneBridge 0.16.2",
          "body": "Fixes and improvements",
          "html_url": "https://github.com/Miraitwo/PhoneBridge/releases/tag/v0.16.2",
          "published_at": "2026-09-11T04:00:00Z",
          "draft": false,
          "prerelease": false
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let release = try decoder.decode(GitHubReleaseResponse.self, from: Data(payload.utf8))

        XCTAssertEqual(release.tagName, "v0.16.2")
        XCTAssertEqual(release.name, "PhoneBridge 0.16.2")
        XCTAssertEqual(release.htmlURL.host, "github.com")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
    }

    @MainActor
    func testManualCheckPublishesNewerGitHubRelease() async throws {
        let payload = #"""
        {
          "tag_name": "v0.16.2",
          "name": "PhoneBridge 0.16.2",
          "body": "Fixes and improvements",
          "html_url": "https://github.com/Miraitwo/PhoneBridge/releases/tag/v0.16.2",
          "published_at": "2026-09-11T04:00:00Z",
          "draft": false,
          "prerelease": false
        }
        """#
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "PhoneBridge/0.16.1")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(payload.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName = "PhoneBridgeTests.UpdateChecker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let checkedAt = Date(timeIntervalSince1970: 2_000_000)
        let checker = AppUpdateChecker(
            session: session,
            defaults: defaults,
            now: { checkedAt },
            currentVersion: { "0.16.1" }
        )

        await checker.checkNow()

        XCTAssertEqual(checker.availableUpdate?.version, "0.16.2")
        XCTAssertEqual(checker.availableUpdate?.currentVersion, "0.16.1")
        XCTAssertEqual(checker.availableUpdate?.releaseNotes, "Fixes and improvements")
        XCTAssertNil(checker.notice)
        XCTAssertEqual(
            defaults.object(forKey: "PhoneBridge.lastSuccessfulUpdateCheck") as? Date,
            checkedAt
        )
    }
}
