import XCTest
@testable import ThinkAloud

final class AudioFileStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPersistMovesFileIntoDateFolder() async throws {
        let fakeWAV = tempDir.appendingPathComponent("temp.wav")
        try Data([0x00, 0x01, 0x02]).write(to: fakeWAV)

        let store = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio", isDirectory: true))
        let date = Date(timeIntervalSince1970: 1_716_854_400) // 2024-05-28 UTC
        let result = try await store.persist(temporaryURL: fakeWAV, recordID: "rec_001", at: date)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.storedURL.path))
        XCTAssertTrue(result.relativePath.hasPrefix("audio/"))
        XCTAssertTrue(result.relativePath.hasSuffix("rec_001.wav"))
    }

    func testDayFolderFormat() {
        let date = Date(timeIntervalSince1970: 1_716_854_400)
        let folder = AudioFileStore.dayFolder(for: date, calendar: .current)
        XCTAssertEqual(folder.count, 10)
        XCTAssertEqual(folder.filter { $0 == "-" }.count, 2)
    }
}
