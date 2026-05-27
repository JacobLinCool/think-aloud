import XCTest
@testable import ThinkAloud

final class JSONLExporterTests: XCTestCase {
    func testExportProducesOneLinePerRecord() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let records = (0..<3).map { i in
            DatasetRecord(
                id: "rec_\(i)",
                createdAt: "2026-05-28T10:00:0\(i)Z",
                audioPath: "audio/2026-05-28/rec_\(i).wav",
                durationMs: 1000 + i,
                sampleRate: 16000,
                channels: 1,
                sourceAppBundleID: nil,
                sourceAppName: nil,
                asrProvider: "mlx-audio-swift",
                asrModel: "model",
                asrRuntime: "runtime",
                asrConfigJSON: nil,
                rawTranscript: "raw \(i)",
                editedTranscript: "edited \(i)",
                inserted: i % 2 == 0,
                savedToDataset: true,
                language: "en",
                metadataJSON: nil
            )
        }
        let url = tempDir.appendingPathComponent("export.jsonl")
        try JSONLExporter.export(records: records, to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)

        let decoder = JSONDecoder()
        for (index, line) in lines.enumerated() {
            let data = Data(line.utf8)
            let decoded = try decoder.decode(DatasetRecord.self, from: data)
            XCTAssertEqual(decoded, records[index])
        }
    }

    func testDefaultExportURLContainsDate() {
        let dir = URL(fileURLWithPath: "/tmp")
        let url = JSONLExporter.makeDefaultExportURL(in: dir, date: Date(timeIntervalSince1970: 1_716_854_400))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("export_"))
        XCTAssertEqual(url.pathExtension, "jsonl")
    }
}
