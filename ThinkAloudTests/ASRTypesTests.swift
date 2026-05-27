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
    }

    func testRecordIDFormat() {
        let id = DatasetRecord.generateID(date: Date(timeIntervalSince1970: 1_716_854_400))
        XCTAssertTrue(id.hasPrefix("rec_"))
        XCTAssertGreaterThan(id.count, 10)
    }
}
