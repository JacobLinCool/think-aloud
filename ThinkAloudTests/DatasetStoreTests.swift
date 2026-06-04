import XCTest
@testable import ThinkAloud

final class DatasetStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTripSaveAndFetch() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        let record = DatasetRecord(
            id: "rec_test_001",
            createdAt: "2026-05-28T10:00:00Z",
            audioPath: "audio/2026-05-28/rec_test_001.wav",
            durationMs: 1234,
            sampleRate: 16000,
            channels: 1,
            sourceAppBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit",
            asrProvider: "mlx-audio-swift",
            asrModel: "mlx-community/Qwen3-ASR-1.7B-4bit",
            asrRuntime: "mlx-audio-swift-qwen3-asr",
            asrConfigJSON: nil,
            rawTranscript: "raw",
            editedTranscript: "edited",
            inserted: true,
            savedToDataset: true,
            language: "zh",
            metadataJSON: nil
        )
        try await store.save(record)

        let count = try await store.count()
        XCTAssertEqual(count, 1)

        let all = try await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, record)
    }

    private func storeCount(_ store: DatasetStore) async throws -> Int {
        try await store.count()
    }

    func testAutoEditedTranscriptRoundTrips() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        // New record carries the auto-edited intermediate.
        var withAuto = makeRecord(id: "rec_auto", createdAt: "2026-06-05T10:00:00Z", raw: "raw model", edited: "final text")
        withAuto.autoEditedTranscript = "auto formatted"
        try await store.save(withAuto)
        let fetchedAuto = try await store.fetch(id: "rec_auto")
        XCTAssertEqual(fetchedAuto?.autoEditedTranscript, "auto formatted")

        // A record that omits it (historical shape) stores/loads NULL → nil.
        let withoutAuto = makeRecord(id: "rec_legacy", createdAt: "2026-06-05T10:00:01Z")
        XCTAssertNil(withoutAuto.autoEditedTranscript, "defaulted to nil when omitted")
        try await store.save(withoutAuto)
        let fetchedLegacy = try await store.fetch(id: "rec_legacy")
        XCTAssertNil(fetchedLegacy?.autoEditedTranscript)
    }

    func testDeleteAll() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        for i in 0..<3 {
            let record = DatasetRecord(
                id: "rec_\(i)",
                createdAt: "2026-05-28T10:00:0\(i)Z",
                audioPath: "audio/2026-05-28/rec_\(i).wav",
                durationMs: 100,
                sampleRate: 16000,
                channels: 1,
                sourceAppBundleID: nil,
                sourceAppName: nil,
                asrProvider: "mlx-audio-swift",
                asrModel: "model",
                asrRuntime: "runtime",
                asrConfigJSON: nil,
                rawTranscript: "raw",
                editedTranscript: "edit",
                inserted: false,
                savedToDataset: true,
                language: nil,
                metadataJSON: nil
            )
            try await store.save(record)
        }
        let preCount = try await store.count()
        XCTAssertEqual(preCount, 3)
        try await store.deleteAll()
        let postCount = try await store.count()
        XCTAssertEqual(postCount, 0)
    }

    func testPagePaginatesNewestFirst() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        for i in 0..<5 {
            try await store.save(makeRecord(id: "rec_\(i)", createdAt: "2026-05-29T10:00:0\(i)Z"))
        }
        let firstPage = try await store.page(offset: 0, limit: 3)
        XCTAssertEqual(firstPage.map(\.id), ["rec_4", "rec_3", "rec_2"])
        let secondPage = try await store.page(offset: 3, limit: 3)
        XCTAssertEqual(secondPage.map(\.id), ["rec_1", "rec_0"])
    }

    func testFetchByID() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        try await store.save(makeRecord(id: "rec_one", createdAt: "2026-05-29T10:00:00Z"))
        let hit = try await store.fetch(id: "rec_one")
        XCTAssertEqual(hit?.id, "rec_one")
        let miss = try await store.fetch(id: "missing")
        XCTAssertNil(miss)
    }

    func testUpdateOverwritesEditedTranscriptOnly() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        let initial = makeRecord(id: "rec_e", createdAt: "2026-05-29T10:00:00Z", raw: "原始輸出", edited: "原始輸出")
        try await store.save(initial)

        try await store.update(id: "rec_e", editedTranscript: "我修過了")
        let after = try await store.fetch(id: "rec_e")
        XCTAssertEqual(after?.rawTranscript, "原始輸出", "raw must never change")
        XCTAssertEqual(after?.editedTranscript, "我修過了")

        // Re-edit overwrites — no history kept.
        try await store.update(id: "rec_e", editedTranscript: "我又修了一次")
        let final = try await store.fetch(id: "rec_e")
        XCTAssertEqual(final?.editedTranscript, "我又修了一次")
        XCTAssertEqual(final?.rawTranscript, "原始輸出")
    }

    func testDeleteByID() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        try await store.save(makeRecord(id: "rec_keep", createdAt: "2026-05-29T10:00:00Z"))
        try await store.save(makeRecord(id: "rec_drop", createdAt: "2026-05-29T10:00:01Z"))
        try await store.delete(id: "rec_drop")
        let count = try await store.count()
        XCTAssertEqual(count, 1)
        let survivor = try await store.fetch(id: "rec_keep")
        XCTAssertNotNil(survivor)
    }

    private func makeRecord(id: String, createdAt: String, raw: String = "raw", edited: String = "edit") -> DatasetRecord {
        DatasetRecord(
            id: id,
            createdAt: createdAt,
            audioPath: "audio/2026-05-29/\(id).wav",
            durationMs: 100, sampleRate: 16000, channels: 1,
            sourceAppBundleID: nil, sourceAppName: nil,
            asrProvider: "mlx-audio-swift", asrModel: "model", asrRuntime: "runtime", asrConfigJSON: nil,
            rawTranscript: raw, editedTranscript: edited,
            inserted: false, savedToDataset: true,
            language: nil, metadataJSON: nil
        )
    }
}
