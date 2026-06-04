import XCTest
@testable import ThinkAloud

/// Locks the uploaded `metadata.jsonl` privacy allowlist: only approved fields ship, source-app is
/// opt-in, free-form blobs never leave, and the auto-edited column is consistent across rows.
final class HFMetadataRowTests: XCTestCase {

    private func record(autoEdited: String?, sourceApp: Bool) -> DatasetRecord {
        DatasetRecord(
            id: "rec_1", createdAt: "2026-06-05T10:00:00Z",
            audioPath: "audio/2026-06-05/rec_1.wav",
            durationMs: 4000, sampleRate: 16000, channels: 1,
            sourceAppBundleID: sourceApp ? "com.apple.Safari" : nil,
            sourceAppName: sourceApp ? "Safari" : nil,
            asrProvider: "mlx-audio-swift", asrModel: "mlx-community/Qwen3-ASR-1.7B-4bit", asrRuntime: "rt",
            asrConfigJSON: "{\"secret\":\"do-not-upload\"}",   // free-form blob — must NOT be published
            rawTranscript: "teh cat", editedTranscript: "the cat",
            inserted: true, savedToDataset: true,
            language: "en", metadataJSON: "{\"device\":\"leak\"}",  // free-form blob — must NOT be published
            autoEditedTranscript: autoEdited
        )
    }

    func testFreeFormBlobsAndInternalFieldsNeverUploaded() {
        let row = HFPushService.metadataRow(for: record(autoEdited: "teh cat", sourceApp: true), includeAudio: true, includeSourceApp: false)
        XCTAssertNil(row["asr_config_json"], "free-form config blob must not be uploaded")
        XCTAssertNil(row["metadata_json"], "free-form metadata blob must not be uploaded")
        XCTAssertNil(row["saved_to_dataset"], "internal flag not part of the public schema")
    }

    func testSourceAppGatedOnOptIn() {
        let off = HFPushService.metadataRow(for: record(autoEdited: nil, sourceApp: true), includeAudio: false, includeSourceApp: false)
        XCTAssertNil(off["source_app_bundle_id"], "source app stripped by default")
        XCTAssertNil(off["source_app_name"])

        let on = HFPushService.metadataRow(for: record(autoEdited: nil, sourceApp: true), includeAudio: false, includeSourceApp: true)
        XCTAssertEqual(on["source_app_name"] as? String, "Safari", "included only when opted in")
    }

    func testAutoEditedAndDerivedFieldsConsistentAcrossRows() {
        // v0.4.0 row: explicit value + computed manual-edit distance.
        let withAuto = HFPushService.metadataRow(for: record(autoEdited: "teh cat", sourceApp: false), includeAudio: true, includeSourceApp: false)
        XCTAssertEqual(withAuto["auto_edited_transcript"] as? String, "teh cat")
        XCTAssertEqual(withAuto["manual_edit_distance"] as? Int, 2, "teh→the = 2 edits, scalar distance")
        XCTAssertEqual(withAuto["raw_char_count"] as? Int, 7)
        XCTAssertEqual(withAuto["edited_char_count"] as? Int, 7)
        XCTAssertNotNil(withAuto["token_count"])
        XCTAssertEqual(withAuto["file_name"] as? String, "audio/2026-06-05/rec_1.wav", "AudioFolder loader needs file_name")

        // Legacy row (no intermediate): the key is present as explicit NSNull, derived edit fields null.
        let legacy = HFPushService.metadataRow(for: record(autoEdited: nil, sourceApp: false), includeAudio: false, includeSourceApp: false)
        XCTAssertTrue(legacy["auto_edited_transcript"] is NSNull, "explicit null, not a missing key")
        XCTAssertTrue(legacy["manual_edit_distance"] is NSNull, "no raw-fallback for manual edits")
        XCTAssertNil(legacy["file_name"], "no file_name when audio excluded")
    }
}
