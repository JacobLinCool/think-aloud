import XCTest
@testable import ThinkAloud

/// Locks the uploaded `metadata.jsonl` privacy allowlist: only approved fields ship, source-app is
/// opt-in, free-form blobs never leave, and the canonical pipeline fields remain complete.
final class HFMetadataRowTests: XCTestCase {

    private func record(autoEdited: String, sourceApp: Bool, llmEdited: String? = nil,
                        raw: String = "teh cat", edited: String = "the cat") -> DatasetRecord {
        DatasetRecord(
            id: "rec_1", createdAt: "2026-06-05T10:00:00Z",
            audioPath: "audio/2026-06-05/rec_1.wav",
            durationMs: 4000, sampleRate: 16000, channels: 1,
            sourceAppBundleID: sourceApp ? "com.apple.Safari" : nil,
            sourceAppName: sourceApp ? "Safari" : nil,
            asrProvider: "mlx-audio-swift", asrModel: "mlx-community/Qwen3-ASR-1.7B-4bit", asrRuntime: "rt",
            asrConfigJSON: "{\"secret\":\"do-not-upload\"}",   // free-form blob — must NOT be published
            rawTranscript: raw, editedTranscript: edited,
            inserted: true,
            language: "en", metadataJSON: "{\"device\":\"leak\"}",  // free-form blob — must NOT be published
            autoEditedTranscript: autoEdited,
            llmEditedTranscript: llmEdited
        )
    }

    func testLLMEditedEmittedAndBecomesManualEditBaseline() {
        // AI Refine ran: raw "teh cat" → auto "teh cat" → llm "the cat" → user kept it verbatim.
        // The human delta must be measured vs the LLM output (0), NOT vs auto (which would be 2).
        let r = record(autoEdited: "teh cat", sourceApp: false, llmEdited: "the cat", raw: "teh cat", edited: "the cat")
        let row = HFPushService.metadataRow(for: r, includeAudio: false, includeSourceApp: false)
        XCTAssertEqual(row["llm_edited_transcript"] as? String, "the cat")
        XCTAssertEqual(row["manual_edit_distance"] as? Int, 0, "baseline is the LLM output → no human edit")

        // No LLM stage: explicit null, with the required Auto Post-Edit output as the baseline.
        let noLLM = record(autoEdited: "teh cat", sourceApp: false, llmEdited: nil, raw: "teh cat", edited: "the cat")
        let row2 = HFPushService.metadataRow(for: noLLM, includeAudio: false, includeSourceApp: false)
        XCTAssertTrue(row2["llm_edited_transcript"] is NSNull, "explicit null when no LLM stage")
        XCTAssertEqual(row2["manual_edit_distance"] as? Int, 2, "baseline = auto-edited → teh→the = 2")
    }

    func testFreeFormBlobsAndInternalFieldsNeverUploaded() {
        let row = HFPushService.metadataRow(for: record(autoEdited: "teh cat", sourceApp: true), includeAudio: true, includeSourceApp: false)
        XCTAssertNil(row["asr_config_json"], "free-form config blob must not be uploaded")
        XCTAssertNil(row["metadata_json"], "free-form metadata blob must not be uploaded")
        XCTAssertNil(row["saved_to_dataset"], "internal flag not part of the public schema")
    }

    func testSourceAppGatedOnOptIn() {
        let off = HFPushService.metadataRow(
            for: record(autoEdited: "teh cat", sourceApp: true),
            includeAudio: false,
            includeSourceApp: false
        )
        XCTAssertNil(off["source_app_bundle_id"], "source app stripped by default")
        XCTAssertNil(off["source_app_name"])

        let on = HFPushService.metadataRow(
            for: record(autoEdited: "teh cat", sourceApp: true),
            includeAudio: false,
            includeSourceApp: true
        )
        XCTAssertEqual(on["source_app_name"] as? String, "Safari", "included only when opted in")
    }

    func testCanonicalAutoEditedAndDerivedFieldsAreAlwaysConcrete() {
        let withAuto = HFPushService.metadataRow(for: record(autoEdited: "teh cat", sourceApp: false), includeAudio: true, includeSourceApp: false)
        XCTAssertEqual(withAuto["auto_edited_transcript"] as? String, "teh cat")
        XCTAssertEqual(withAuto["manual_edit_distance"] as? Int, 2, "teh→the = 2 edits, scalar distance")
        XCTAssertEqual(withAuto["raw_char_count"] as? Int, 7)
        XCTAssertEqual(withAuto["edited_char_count"] as? Int, 7)
        XCTAssertNotNil(withAuto["token_count"])
        XCTAssertEqual(withAuto["file_name"] as? String, "audio/2026-06-05/rec_1.wav", "AudioFolder loader needs file_name")

        let withoutAudio = HFPushService.metadataRow(
            for: record(autoEdited: "teh cat", sourceApp: false),
            includeAudio: false,
            includeSourceApp: false
        )
        XCTAssertEqual(withoutAudio["auto_edited_transcript"] as? String, "teh cat")
        XCTAssertEqual(withoutAudio["manual_edit_distance"] as? Int, 2)
        XCTAssertEqual(withoutAudio["manual_edit_rate"] as? Double, 2.0 / 7.0)
        XCTAssertNil(withoutAudio["file_name"], "no file_name when audio excluded")
    }

    func testLegacyRowPublishesUnknownIntermediateAndMetricsAsNull() {
        var legacy = record(autoEdited: "placeholder", sourceApp: false)
        legacy.autoEditedTranscript = nil

        let row = HFPushService.metadataRow(
            for: legacy,
            includeAudio: false,
            includeSourceApp: false
        )
        XCTAssertTrue(row["auto_edited_transcript"] is NSNull)
        XCTAssertTrue(row["manual_edit_distance"] is NSNull)
        XCTAssertTrue(row["manual_edit_rate"] is NSNull)
    }
}
