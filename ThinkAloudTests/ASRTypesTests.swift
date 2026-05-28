import XCTest
@testable import ThinkAloud

final class ASRTypesTests: XCTestCase {
    func testStatusFlags() {
        XCTAssertTrue(ASRRuntimeStatus.ready.isReady)
        XCTAssertFalse(ASRRuntimeStatus.unloaded.isReady)
        XCTAssertTrue(ASRRuntimeStatus.loading.isLoading)
        XCTAssertFalse(ASRRuntimeStatus.ready.isLoading)
    }

    func testProfileMapping() {
        XCTAssertEqual(ModelProfile.fast.modelID, "mlx-community/Qwen3-ASR-0.6B-4bit")
        XCTAssertEqual(ModelProfile.balanced.modelID, "mlx-community/Qwen3-ASR-1.7B-4bit")
        XCTAssertEqual(ModelProfile.accurate.modelID, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(ModelProfile.whisperLargeV3Turbo.modelID, "mlx-community/whisper-large-v3-turbo")
        XCTAssertEqual(ModelProfile.breezeASR25.modelID, "MediaTek-Research/Breeze-ASR-25")
    }

    func testProfileFamily() {
        XCTAssertEqual(ModelProfile.fast.family, .qwen3)
        XCTAssertEqual(ModelProfile.balanced.family, .qwen3)
        XCTAssertEqual(ModelProfile.accurate.family, .qwen3)
        XCTAssertEqual(ModelProfile.whisperLargeV3Turbo.family, .whisper)
        XCTAssertEqual(ModelProfile.breezeASR25.family, .whisper)
    }

    func testRecordIDFormat() {
        let id = DatasetRecord.generateID(date: Date(timeIntervalSince1970: 1_716_854_400))
        XCTAssertTrue(id.hasPrefix("rec_"))
        XCTAssertGreaterThan(id.count, 10)
    }
}
