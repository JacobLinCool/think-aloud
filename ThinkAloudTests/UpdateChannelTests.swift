import XCTest
@testable import ThinkAloud

final class UpdateChannelTests: XCTestCase {
    func testCasesAndRawValues() {
        XCTAssertEqual(UpdateChannel.allCases, [.stable, .dev])
        XCTAssertEqual(UpdateChannel(rawValue: "stable"), .stable)
        XCTAssertEqual(UpdateChannel(rawValue: "dev"), .dev)
        XCTAssertNil(UpdateChannel(rawValue: "nightly"))
    }

    func testFeedURLs() {
        // Stable follows `latest` (ignores prereleases); dev is the fixed `dev` prerelease feed.
        XCTAssertEqual(UpdateChannel.stable.feedURLString,
                       "https://github.com/JacobLinCool/think-aloud/releases/latest/download/appcast.xml")
        XCTAssertEqual(UpdateChannel.dev.feedURLString,
                       "https://github.com/JacobLinCool/think-aloud/releases/download/dev/appcast-dev.xml")
        // The two channels must point at different feeds.
        XCTAssertNotEqual(UpdateChannel.stable.feedURLString, UpdateChannel.dev.feedURLString)
    }
}
