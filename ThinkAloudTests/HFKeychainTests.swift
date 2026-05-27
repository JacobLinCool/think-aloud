import XCTest
@testable import ThinkAloud

final class HFKeychainTests: XCTestCase {
    private let testService = "com.jacoblincool.thinkaloud.tests.keychain"
    private let testAccount = "test"

    override func tearDown() async throws {
        // Ensure no leftover items between runs.
        try? HFKeychain.delete(service: testService, account: testAccount)
    }

    func testRoundTripSaveAndRead() throws {
        try HFKeychain.set("hf_test_secret_abc", service: testService, account: testAccount)
        let read = HFKeychain.get(service: testService, account: testAccount)
        XCTAssertEqual(read, "hf_test_secret_abc")
    }

    func testOverwriteReplacesValue() throws {
        try HFKeychain.set("v1", service: testService, account: testAccount)
        try HFKeychain.set("v2", service: testService, account: testAccount)
        XCTAssertEqual(HFKeychain.get(service: testService, account: testAccount), "v2")
    }

    func testDeleteRemoves() throws {
        try HFKeychain.set("temp", service: testService, account: testAccount)
        try HFKeychain.delete(service: testService, account: testAccount)
        XCTAssertNil(HFKeychain.get(service: testService, account: testAccount))
    }

    func testDeleteMissingIsIdempotent() throws {
        // Should not throw even when nothing exists.
        XCTAssertNoThrow(try HFKeychain.delete(service: testService, account: testAccount))
    }
}
