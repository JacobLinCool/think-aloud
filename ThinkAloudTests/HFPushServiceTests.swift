import XCTest

@testable import ThinkAloud

final class HFPushServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloudHFPushTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMissingAudioStopsBeforeAnyRemoteMutation() async throws {
        let (dataset, audio) = try await Self.makeStores(in: tempDir, writeAudio: false)
        let client = StubHFClient(repoIsPrivate: true)
        let service = HFPushService(
            client: client,
            datasetStore: dataset,
            audioFileStore: audio,
            defaultOwner: "owner"
        )

        do {
            _ = try await service.push(options: options(isPrivate: true))
            XCTFail("Expected missing audio to block upload")
        } catch let error as HFPushService.PushError {
            guard case .missingAudioFiles(let paths) = error else {
                return XCTFail("Unexpected push error: \(error)")
            }
            XCTAssertEqual(paths, ["audio/2026-07-31/rec.wav"])
        }
        let mutationCount = await client.remoteMutationCount
        XCTAssertEqual(mutationCount, 0)
    }

    func testVisibilityIsAppliedAndVerifiedBeforeCommit() async throws {
        let (dataset, audio) = try await Self.makeStores(in: tempDir, writeAudio: true)
        let client = StubHFClient(repoIsPrivate: true)
        let service = HFPushService(
            client: client,
            datasetStore: dataset,
            audioFileStore: audio,
            defaultOwner: "owner"
        )

        _ = try await service.push(options: options(isPrivate: true))

        let events = await client.events
        XCTAssertEqual(events, ["create", "visibility", "info", "preupload", "commit"])
    }

    func testVisibilityMismatchBlocksCommit() async throws {
        let (dataset, audio) = try await Self.makeStores(in: tempDir, writeAudio: true)
        let client = StubHFClient(repoIsPrivate: false)
        let service = HFPushService(
            client: client,
            datasetStore: dataset,
            audioFileStore: audio,
            defaultOwner: "owner"
        )

        do {
            _ = try await service.push(options: options(isPrivate: true))
            XCTFail("Expected visibility mismatch")
        } catch let error as HFPushService.PushError {
            guard case .visibilityMismatch = error else {
                return XCTFail("Unexpected push error: \(error)")
            }
        }
        let events = await client.events
        XCTAssertFalse(events.contains("commit"))
    }

    func testPreCommitFailureAndCleanupFailureReturnCombinedTypedError() async throws {
        let (dataset, audio) = try await Self.makeStores(in: tempDir, writeAudio: true)
        let client = StubHFClient(repoIsPrivate: true, failureStage: .preupload)
        let batchName = "ThinkAloudPush-precommit-cleanup"
        let fileManager = PushCleanupFailingFileManager(failingDirectoryName: batchName)
        let service = HFPushService(
            client: client,
            datasetStore: dataset,
            audioFileStore: audio,
            defaultOwner: "owner",
            fileManager: fileManager,
            stagingRoot: tempDir,
            makeStagingID: { "precommit-cleanup" }
        )

        do {
            _ = try await service.push(options: options(isPrivate: true))
            XCTFail("Expected combined operation and cleanup failure")
        } catch let error as HFPushService.PushError {
            guard
                case .preCommitFailureAndCleanupFailed(
                    let directory,
                    _,
                    _,
                    let wasCancelled
                ) = error
            else {
                return XCTFail("Unexpected push error: \(error)")
            }
            XCTAssertEqual(directory.lastPathComponent, batchName)
            XCTAssertFalse(wasCancelled)
            XCTAssertTrue(error.localizedDescription.contains(directory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
        let events = await client.events
        XCTAssertFalse(events.contains("commit"))
    }

    func testCancelledPreCommitCleanupFailurePreservesCancellationAndExactPath() async throws {
        let (dataset, audio) = try await Self.makeStores(in: tempDir, writeAudio: true)
        let client = StubHFClient(repoIsPrivate: true, failureStage: .cancelAtPreupload)
        let batchName = "ThinkAloudPush-cancel-cleanup"
        let service = HFPushService(
            client: client,
            datasetStore: dataset,
            audioFileStore: audio,
            defaultOwner: "owner",
            fileManager: PushCleanupFailingFileManager(failingDirectoryName: batchName),
            stagingRoot: tempDir,
            makeStagingID: { "cancel-cleanup" }
        )

        do {
            _ = try await service.push(options: options(isPrivate: true))
            XCTFail("Expected combined cancellation and cleanup failure")
        } catch let error as HFPushService.PushError {
            guard
                case .preCommitFailureAndCleanupFailed(
                    let directory,
                    _,
                    _,
                    let wasCancelled
                ) = error
            else {
                return XCTFail("Unexpected push error: \(error)")
            }
            XCTAssertTrue(wasCancelled)
            XCTAssertTrue(error.localizedDescription.contains(directory.path))
            XCTAssertTrue(error.localizedDescription.contains("LFS"))
        }
    }

    func testPostCommitCleanupFailureReturnsCommittedResultWithWarning() async throws {
        let (dataset, audio) = try await Self.makeStores(in: tempDir, writeAudio: true)
        let client = StubHFClient(repoIsPrivate: true)
        let batchName = "ThinkAloudPush-postcommit-cleanup"
        let service = HFPushService(
            client: client,
            datasetStore: dataset,
            audioFileStore: audio,
            defaultOwner: "owner",
            fileManager: PushCleanupFailingFileManager(failingDirectoryName: batchName),
            stagingRoot: tempDir,
            makeStagingID: { "postcommit-cleanup" }
        )

        let result = try await service.push(options: options(isPrivate: true))

        XCTAssertEqual(result.repoID, "owner/dataset")
        XCTAssertEqual(result.cleanupWarning?.directory.lastPathComponent, batchName)
        XCTAssertTrue(
            result.cleanupWarning.map {
                FileManager.default.fileExists(atPath: $0.directory.path)
            } ?? false
        )
        let events = await client.events
        XCTAssertTrue(events.contains("commit"))
    }

    func testStagingDirectoryCreationFailureDoesNotAttemptMisleadingCleanup() async throws {
        let (dataset, audio) = try await Self.makeStores(in: tempDir, writeAudio: false)
        let removalCounter = LockedCounter()
        let fileManager = PushCreateFailingFileManager(removalCounter: removalCounter)
        let service = HFPushService(
            client: StubHFClient(repoIsPrivate: true),
            datasetStore: dataset,
            audioFileStore: audio,
            defaultOwner: "owner",
            fileManager: fileManager,
            stagingRoot: tempDir,
            makeStagingID: { "create-failure" }
        )

        do {
            _ = try await service.push(options: options(isPrivate: true, includeAudio: false))
            XCTFail("Expected staging directory creation to fail")
        } catch is HFPushService.PushError {
            XCTFail("A pre-staging failure must not be rewritten as a cleanup failure")
        } catch {
            // The original createDirectory error is preserved.
        }
        XCTAssertEqual(removalCounter.value, 0)
    }

    func testDestinationValidationUsesTrimmedCanonicalNames() {
        XCTAssertNotNil(HFPushValidation.destinationError(repoName: " repo", organization: ""))
        XCTAssertNotNil(HFPushValidation.destinationError(repoName: "repo/name", organization: ""))
        XCTAssertNil(
            HFPushValidation.destinationError(repoName: "valid-repo_1", organization: "valid-org"))
    }

    @MainActor
    func testShortSpeechDurationUsesSecondsInsteadOfRoundingToZeroHours() {
        let rendered = HFPushView.formattedSpeechDuration(milliseconds: 30_000)
        let expected = Measurement(value: 30, unit: UnitDuration.seconds).formatted(
            .measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0...1))
            )
        )
        XCTAssertEqual(rendered, expected)
    }

    func testHTTPFailuresExposeActionableMessagesWithoutResponseBodies() {
        let expectations: [(Int, String)] = [
            (401, String(localized: "Your Hugging Face token is invalid or expired. Update the token and try again.")),
            (403, String(localized: "Your Hugging Face account does not have permission to update this dataset. Check the token permissions and repository access.")),
            (404, String(localized: "Hugging Face could not find this dataset repository. Check the destination and your repository access.")),
            (413, String(localized: "The upload request is too large. Reduce the dataset size and try again.")),
            (429, String(localized: "Hugging Face is receiving too many requests. Wait a moment, then try again.")),
            (503, String(localized: "Hugging Face is temporarily unavailable. Try again later.")),
            (418, String(localized: "Hugging Face could not complete the request. Check your connection and try again.")),
        ]

        for (status, expectedMessage) in expectations {
            let message = HFHubClient.HFError.httpStatus(status).localizedDescription
            XCTAssertEqual(message, expectedMessage, "Unexpected user-facing message for HTTP \(status)")
            XCTAssertFalse(message.contains("<html>"))
            XCTAssertFalse(message.contains(String(status)))
        }
    }

    func testInternalHFDiagnosticsAreNotShownInLocalizedDescriptions() {
        let serverDiagnostic = "<html>private upstream response</html>"
        XCTAssertFalse(
            HFHubClient.HFError.malformedResponse(serverDiagnostic)
                .localizedDescription
                .contains(serverDiagnostic)
        )
        XCTAssertFalse(
            HFHubClient.HFError.lfsError(serverDiagnostic)
                .localizedDescription
                .contains(serverDiagnostic)
        )
    }

    @MainActor
    func testPrepareForPresentationClearsTransientOutcomesAndRecomputesSummary() async throws {
        let root = tempDir!
        let (dataset, audio) = try await Self.makeStores(in: root, writeAudio: true)
        let auth = StubHFAuthStore(token: "test-token")

        let successfulController = HFPushController(
            tokenStore: auth,
            datasetStore: dataset,
            audioFileStore: audio,
            clientFactory: { _ in StubHFClient(repoIsPrivate: true) }
        )
        await successfulController.prepareForPresentation()
        XCTAssertEqual(summaryRecordCount(successfulController.summaryState), 1)
        successfulController.push()
        try await waitUntilFinished(successfulController)
        XCTAssertNotNil(successfulController.result)

        try await dataset.save(Self.makeRecord(id: "rec_second"))
        await successfulController.prepareForPresentation()
        XCTAssertNil(successfulController.result)
        XCTAssertNil(successfulController.errorMessage)
        XCTAssertFalse(successfulController.wasCancelled)
        XCTAssertEqual(summaryRecordCount(successfulController.summaryState), 2)

        let failingController = HFPushController(
            tokenStore: auth,
            datasetStore: dataset,
            audioFileStore: audio,
            clientFactory: { _ in
                StubHFClient(repoIsPrivate: true, failureStage: .preupload)
            }
        )
        failingController.includeAudio = false
        await failingController.prepareForPresentation()
        failingController.push()
        try await waitUntilFinished(failingController)
        XCTAssertNotNil(failingController.errorMessage)
        await failingController.prepareForPresentation()
        XCTAssertNil(failingController.errorMessage)

        let cancelledController = HFPushController(
            tokenStore: auth,
            datasetStore: dataset,
            audioFileStore: audio,
            clientFactory: { _ in
                StubHFClient(repoIsPrivate: true, failureStage: .cancelAtPreupload)
            }
        )
        cancelledController.includeAudio = false
        await cancelledController.prepareForPresentation()
        cancelledController.push()
        try await waitUntilFinished(cancelledController)
        XCTAssertTrue(cancelledController.wasCancelled)
        await cancelledController.prepareForPresentation()
        XCTAssertFalse(cancelledController.wasCancelled)
    }

    private func options(
        isPrivate: Bool,
        includeAudio: Bool = true
    ) -> HFPushOptions {
        HFPushOptions(
            repoName: "dataset",
            organization: nil,
            isPrivate: isPrivate,
            includeAudio: includeAudio,
            includeSourceApp: false
        )
    }

    private static func makeStores(
        in root: URL,
        writeAudio: Bool
    ) async throws -> (DatasetStore, AudioFileStore) {
        let dataset = DatasetStore(databaseURL: root.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: root.appendingPathComponent("audio"))
        let record = makeRecord(id: "rec")
        try await dataset.save(record)
        if writeAudio {
            let url = try await audio.validatedAbsoluteURL(for: record.audioPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([1, 2, 3]).write(to: url)
        }
        return (dataset, audio)
    }

    private static func makeRecord(id: String) -> DatasetRecord {
        DatasetRecord(
            id: id,
            createdAt: "2026-07-31T00:00:00Z",
            audioPath: "audio/2026-07-31/\(id).wav",
            durationMs: 100,
            sampleRate: 16_000,
            channels: 1,
            sourceAppBundleID: nil,
            sourceAppName: nil,
            asrProvider: "test",
            asrModel: "test",
            asrRuntime: "test",
            asrConfigJSON: nil,
            rawTranscript: "raw",
            editedTranscript: "edited",
            inserted: true,
            language: "zh",
            metadataJSON: nil,
            autoEditedTranscript: "edited"
        )
    }

    @MainActor
    private func waitUntilFinished(_ controller: HFPushController) async throws {
        while controller.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func summaryRecordCount(
        _ state: HFPushController.SummaryState
    ) -> Int? {
        guard case .loaded(let summary) = state else { return nil }
        return summary.recordCount
    }
}

@MainActor
private final class StubHFAuthStore: HFAuthStore {
    let token: String?
    var verifiedUsername: String?
    var hasToken: Bool { token?.isEmpty == false }
    var accessError: String? { nil }

    init(token: String?) {
        self.token = token
    }
}

private actor StubHFClient: HFHubClientProtocol {
    enum StubError: Error {
        case unexpectedLFSCall
        case preuploadFailed
    }

    enum FailureStage {
        case none
        case preupload
        case cancelAtPreupload
    }

    private let repoIsPrivate: Bool
    private let failureStage: FailureStage
    private(set) var events: [String] = []

    init(repoIsPrivate: Bool, failureStage: FailureStage = .none) {
        self.repoIsPrivate = repoIsPrivate
        self.failureStage = failureStage
    }

    var remoteMutationCount: Int {
        events.filter { ["create", "visibility", "commit"].contains($0) }.count
    }

    func whoami() async throws -> HFHubClient.WhoAmI {
        .init(name: "owner", email: nil, type: nil)
    }

    func createDatasetRepo(name: String, organization: String?, isPrivate: Bool) async throws {
        events.append("create")
    }

    func updateDatasetRepoVisibility(repoID: String, isPrivate: Bool) async throws {
        events.append("visibility")
    }

    func datasetRepoInfo(repoID: String) async throws -> HFHubClient.DatasetRepoInfo {
        events.append("info")
        return .init(id: repoID, isPrivate: repoIsPrivate)
    }

    func preupload(
        repoID: String,
        files: [HFHubClient.PreuploadFileEntry],
        revision: String
    ) async throws -> [HFHubClient.PreuploadResponseFile] {
        events.append("preupload")
        switch failureStage {
        case .none:
            break
        case .preupload:
            throw StubError.preuploadFailed
        case .cancelAtPreupload:
            throw CancellationError()
        }
        return files.map {
            .init(path: $0.path, uploadMode: "regular", shouldIgnore: false)
        }
    }

    func lfsBatch(
        repoID: String,
        objects: [HFHubClient.LFSObject],
        revision: String
    ) async throws -> [HFHubClient.LFSUploadInstruction] {
        throw StubError.unexpectedLFSCall
    }

    func lfsUpload(instruction: HFHubClient.LFSUploadInstruction, fileURL: URL) async throws {
        throw StubError.unexpectedLFSCall
    }

    func lfsVerify(instruction: HFHubClient.LFSUploadInstruction) async throws {
        throw StubError.unexpectedLFSCall
    }

    func commit(
        repoID: String,
        operations: [HFHubClient.CommitOp],
        revision: String
    ) async throws -> HFHubClient.CommitResult {
        events.append("commit")
        return .init(
            commitOid: "abc", commitURL: "https://example.test/commit/abc", pullRequestURL: nil)
    }
}

private final class PushCleanupFailingFileManager: FileManager, @unchecked Sendable {
    private let failingDirectoryName: String

    init(failingDirectoryName: String) {
        self.failingDirectoryName = failingDirectoryName
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent == failingDirectoryName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

private final class PushCreateFailingFileManager: FileManager, @unchecked Sendable {
    private let removalCounter: LockedCounter

    init(removalCounter: LockedCounter) {
        self.removalCounter = removalCounter
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if url.lastPathComponent.hasPrefix("ThinkAloudPush-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    override func removeItem(at URL: URL) throws {
        removalCounter.increment()
        try super.removeItem(at: URL)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock {
            storedValue += 1
        }
    }
}
