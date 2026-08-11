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

    func testUnitTestHostSkipsAppBootstrapButUITestingDoesNot() {
        XCTAssertFalse(
            AppBootstrapPolicy.shouldBootstrap(
                arguments: ["ThinkAloud"],
                environment: ["XCTestConfigurationFilePath": "/tmp/unit-tests.xctestconfiguration"]
            )
        )
        XCTAssertFalse(
            AppBootstrapPolicy.shouldBootstrap(
                arguments: ["ThinkAloud"],
                environment: ["XCInjectBundleInto": "/Applications/ThinkAloud.app/Contents/MacOS/ThinkAloud"]
            )
        )
        XCTAssertTrue(
            AppBootstrapPolicy.shouldBootstrap(
                arguments: ["ThinkAloud", "--ui-testing"],
                environment: ["XCTestConfigurationFilePath": "/tmp/ui-tests.xctestconfiguration"]
            )
        )
        XCTAssertTrue(
            AppBootstrapPolicy.shouldBootstrap(
                arguments: ["ThinkAloud"],
                environment: [:]
            )
        )
    }

    @MainActor
    func testManualUpdateCheckIsAvailableBeforeScheduledUpdaterStarts() {
        let updater = UpdaterController()
        XCTAssertTrue(updater.canCheckForUpdates)
    }

    #if DEBUG
    func testUITestingConfigurationRequiresAndUsesAnIsolatedSurface() throws {
        let config = try AppRuntimeConfiguration.resolve(
            arguments: ["ThinkAloud", "--ui-testing", "--ui-test-surface", "settings"],
            environment: ["THINKALOUD_UI_TEST_ROOT": "/tmp/thinkaloud-ui-test"],
            defaultApplicationSupportDirectory: URL(fileURLWithPath: "/production")
        )

        XCTAssertEqual(config.applicationSupportDirectory.path, "/tmp/thinkaloud-ui-test")
        XCTAssertEqual(config.uiTestSurface, .settings)
        XCTAssertFalse(config.allowsScheduledUpdates)
        XCTAssertFalse(config.bindsGlobalHotkeys)
    }

    func testUITestingConfigurationRejectsMissingIsolationRoot() {
        XCTAssertThrowsError(
            try AppRuntimeConfiguration.resolve(
                arguments: ["ThinkAloud", "--ui-testing", "--ui-test-surface", "onboarding"],
                environment: [:],
                defaultApplicationSupportDirectory: URL(fileURLWithPath: "/production")
            )
        ) { error in
            XCTAssertEqual(
                error as? AppRuntimeConfiguration.ConfigurationError,
                .missingUITestApplicationSupportRoot
            )
        }
    }

    func testUITestingConfigurationRejectsUnknownSurface() {
        XCTAssertThrowsError(
            try AppRuntimeConfiguration.resolve(
                arguments: ["ThinkAloud", "--ui-testing", "--ui-test-surface", "unknown"],
                environment: ["THINKALOUD_UI_TEST_ROOT": "/tmp/thinkaloud-ui-test"],
                defaultApplicationSupportDirectory: URL(fileURLWithPath: "/production")
            )
        ) { error in
            XCTAssertEqual(
                error as? AppRuntimeConfiguration.ConfigurationError,
                .invalidUITestSurface("unknown")
            )
        }
    }
    #endif

    @MainActor
    func testOnboardingCompletionIsExplicitAndReadinessRequiresOnlyRequiredItems() {
        let suiteName = "UpdateChannelTests.Onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = OnboardingState(defaults: defaults)

        XCTAssertFalse(state.isCompleted)
        state.rewind()
        XCTAssertFalse(state.isCompleted, "Opening or closing without an explicit outcome must not complete setup")
        state.markCompleted()
        XCTAssertTrue(state.isCompleted)

        XCTAssertFalse(OnboardingReadiness(microphoneGranted: false, modelReady: true).canFinish)
        XCTAssertFalse(OnboardingReadiness(microphoneGranted: true, modelReady: false).canFinish)
        XCTAssertTrue(OnboardingReadiness(microphoneGranted: true, modelReady: true).canFinish)
    }

    func testPopupFailuresCarryTypedRecoveryDestinations() {
        let offline = NSError(
            domain: "UpdateChannelTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )
        XCTAssertEqual(PopupFailure.microphonePermission.kind, .microphonePermission)
        XCTAssertEqual(PopupFailure.microphonePermission.destination, .permissions)
        XCTAssertEqual(PopupFailure.recording(offline).destination, .permissions)
        XCTAssertEqual(PopupFailure.denoise(offline).destination, .audioCleanup)
        XCTAssertEqual(PopupFailure.audioProcessing(offline).destination, .audioCleanup)
        XCTAssertEqual(PopupFailure.transcription(offline).destination, .speechModel)
        XCTAssertEqual(PopupFailure.canonicalData.kind, .canonicalData)
        XCTAssertNil(PopupFailure.canonicalData.destination)
        XCTAssertEqual(PopupFailure.canonicalData.retryTitle, String(localized: "Record Again"))
        XCTAssertEqual(
            PopupFailure.canonicalData.message,
            String(
                localized: "ThinkAloud stopped before inserting or saving because the speech model didn’t return a complete final result. Record again to create a complete session."
            )
        )
        XCTAssertEqual(PopupFailure.historySave(inserted: true).kind, .historySave)
        XCTAssertNil(PopupFailure.historySave(inserted: true).destination)
        XCTAssertEqual(PopupFailure.datasetSave(inserted: true).destination, .dataset)
        XCTAssertEqual(
            PopupFailure.datasetSave(inserted: true).title,
            String(localized: "Text inserted, but save failed")
        )
        XCTAssertEqual(
            PopupFailure.datasetSave(inserted: false).title,
            String(localized: "Text wasn’t inserted, and save failed")
        )
        let insertionContext = "Paste the copied transcript manually."
        let cleanupFailure = PopupFailure.datasetSave(
            inserted: false,
            cleanupFailed: true,
            insertionMessage: insertionContext
        )
        XCTAssertEqual(
            cleanupFailure.message,
            String(
                localized: "\(insertionContext) ThinkAloud also couldn’t save the recording to the local dataset or remove its temporary audio. This recovery remains open: choose Retry Save, or check Dataset settings, file permissions, and available disk space before choosing Close again."
            )
        )
        XCTAssertFalse(cleanupFailure.message.contains("permission denied"))
    }

    func testMenuPresentationTracksEveryPopupPhase() {
        XCTAssertEqual(PopupMenuPresentation(phase: .idle).systemImage, "mic.fill")
        XCTAssertEqual(PopupMenuPresentation(phase: .recording).systemImage, "stop.circle.fill")
        XCTAssertEqual(PopupMenuPresentation(phase: .transcribing).systemImage, "waveform")
        XCTAssertFalse(PopupMenuPresentation(phase: .inserting).isEnabled)
        XCTAssertEqual(PopupMenuPresentation(phase: .polishing).systemImage, "wand.and.stars")
        XCTAssertEqual(PopupMenuPresentation(phase: .review).systemImage, "text.cursor")
        XCTAssertFalse(PopupMenuPresentation(phase: .savingDataset).isEnabled)
        XCTAssertEqual(
            PopupMenuPresentation(phase: .error(.noSpeech)).systemImage,
            "exclamationmark.triangle.fill"
        )
        XCTAssertTrue(PopupPhase.idle.allowsNewRecordingInvocation)
        XCTAssertTrue(PopupPhase.error(.noSpeech).allowsNewRecordingInvocation)
        XCTAssertFalse(
            PopupPhase.error(.datasetSave(inserted: true)).allowsNewRecordingInvocation,
            "A new recording must not discard the pending dataset-save retry snapshot"
        )
        XCTAssertFalse(
            PopupPhase.error(.historySave(inserted: true)).allowsNewRecordingInvocation,
            "A new recording must not discard the pending history retry snapshot"
        )
        XCTAssertFalse(PopupPhase.savingDataset.allowsNewRecordingInvocation)
    }

    @MainActor
    func testSettingsRouterPrefersDeepLinkThenSavedPaneThenInsights() {
        let suiteName = "UpdateChannelTests.SettingsRouter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SettingsRouter(defaults: defaults).selection, .insights)
        let first = SettingsRouter(defaults: defaults)
        first.selection = .output
        XCTAssertEqual(SettingsRouter(defaults: defaults).selection, .output)
        XCTAssertEqual(SettingsRouter(initial: .permissions, defaults: defaults).selection, .permissions)
        XCTAssertEqual(SettingsRouter(defaults: defaults).selection, .permissions)
    }

    func testModelDownloadSpaceRequirementUsesProfileSizeAndSafetyMargin() {
        let small = ModelDownloadSpaceRequirement(downloadBytes: 500_000_000)
        XCTAssertEqual(small.peakModelBytes, 1_000_000_000)
        XCTAssertEqual(small.safetyMarginBytes, 500_000_000)
        XCTAssertEqual(small.requiredAvailableBytes, 1_500_000_000)

        let large = ModelDownloadSpaceRequirement(downloadBytes: 3_000_000_000)
        XCTAssertEqual(large.peakModelBytes, 6_000_000_000)
        XCTAssertEqual(large.safetyMarginBytes, 600_000_000)
        XCTAssertEqual(large.requiredAvailableBytes, 6_600_000_000)
    }

    @MainActor
    func testRemovingNonSelectedRefineModelUpdatesObservedDownloadState() throws {
        let fileManager = FileManager.default
        let cacheDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ThinkAloud-LLMRemoval-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }
        }

        let suiteName = "UpdateChannelTests.LLMRemoval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selected = LLMModelProfile.recommended
        let profile = try XCTUnwrap(LLMModelProfile.allCases.first { $0 != selected })
        let repoName = "models--" + profile.modelID.replacingOccurrences(of: "/", with: "--")
        let snapshot = cacheDirectory
            .appendingPathComponent(repoName, isDirectory: true)
            .appendingPathComponent("snapshots/test-revision", isDirectory: true)
        try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data([0]).write(to: snapshot.appendingPathComponent("model.safetensors"))

        let manager = try LLMManager(cacheDirectory: cacheDirectory, defaults: defaults)
        XCTAssertTrue(manager.isDownloaded(profile))

        try manager.removeModel(profile)

        XCTAssertFalse(manager.isDownloaded(profile))
        XCTAssertFalse(manager.downloadedProfiles.contains(profile))
    }

    func testModelProfilesExposeVerifiedDownloaderBytesAndMatchingRules() {
        XCTAssertEqual(ModelProfile.fast.estimatedDownloadBytes, 712_778_752)
        XCTAssertEqual(ModelProfile.balanced.estimatedDownloadBytes, 1_607_630_579)
        XCTAssertEqual(ModelProfile.accurate.estimatedDownloadBytes, 2_467_856_503)
        XCTAssertEqual(ModelProfile.whisperLargeV3Turbo.estimatedDownloadBytes, 1_613_977_880)
        XCTAssertEqual(ModelProfile.breezeASR25.estimatedDownloadBytes, 3_092_400_389)

        XCTAssertTrue(
            HuggingFaceMetadata.matches(
                path: "weights/model-00001-of-00002.safetensors",
                matchingPatterns: ModelProfile.accurate.downloadMatchingPatterns
            )
        )
        XCTAssertTrue(
            HuggingFaceMetadata.matches(
                path: "tokenizer/merges.txt",
                matchingPatterns: ModelProfile.whisperLargeV3Turbo.downloadMatchingPatterns
            )
        )
        XCTAssertFalse(
            HuggingFaceMetadata.matches(
                path: "training/optimizer.bin",
                matchingPatterns: ModelProfile.breezeASR25.downloadMatchingPatterns
            )
        )
        XCTAssertFalse(
            HuggingFaceMetadata.matches(
                path: "pytorch_model.pt",
                matchingPatterns: ModelProfile.breezeASR25.downloadMatchingPatterns
            )
        )
    }

    func testAppPathsSurfaceDirectoryCreationFailures() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ThinkAloud-AppPaths-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            if fileManager.fileExists(atPath: root.path) {
                try fileManager.removeItem(at: root)
            }
        }

        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockingFile)
        let requestedDirectory = blockingFile.appendingPathComponent("models", isDirectory: true)

        XCTAssertThrowsError(try AppPaths.ensureDirectoryExists(requestedDirectory)) { error in
            guard case AppPaths.StartupError.directoryCreationFailed(let failedURL, _) = error else {
                return XCTFail("Expected a typed directory creation error, got \(error)")
            }
            XCTAssertEqual(failedURL, requestedDirectory)
        }
    }
}
