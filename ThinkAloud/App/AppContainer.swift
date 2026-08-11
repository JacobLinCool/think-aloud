import Foundation
import Observation

struct AppRuntimeConfiguration: Equatable, Sendable {
    enum UITestSurface: String, Equatable, Sendable {
        case onboarding
        case settings
        case dataset
    }

    enum ConfigurationError: LocalizedError, Equatable {
        case missingUITestApplicationSupportRoot
        case invalidUITestApplicationSupportRoot(String)
        case missingUITestSurface
        case invalidUITestSurface(String)

        var errorDescription: String? {
            switch self {
            case .missingUITestApplicationSupportRoot:
                return "UI testing requires THINKALOUD_UI_TEST_ROOT to name an isolated directory."
            case .invalidUITestApplicationSupportRoot(let path):
                return "THINKALOUD_UI_TEST_ROOT must be an absolute directory path: \(path)"
            case .missingUITestSurface:
                return "--ui-testing requires --ui-test-surface onboarding, settings, or dataset."
            case .invalidUITestSurface(let value):
                return "Invalid --ui-test-surface value: \(value)"
            }
        }
    }

    let applicationSupportDirectory: URL
    let allowsScheduledUpdates: Bool
    let bindsGlobalHotkeys: Bool
    let uiTestSurface: UITestSurface?

    static func resolve(
        arguments: [String],
        environment: [String: String],
        defaultApplicationSupportDirectory: URL
    ) throws -> AppRuntimeConfiguration {
        #if DEBUG
        if arguments.contains("--ui-testing") {
            guard let rawRoot = environment["THINKALOUD_UI_TEST_ROOT"], !rawRoot.isEmpty else {
                throw ConfigurationError.missingUITestApplicationSupportRoot
            }
            guard rawRoot.hasPrefix("/") else {
                throw ConfigurationError.invalidUITestApplicationSupportRoot(rawRoot)
            }
            guard let flagIndex = arguments.firstIndex(of: "--ui-test-surface"),
                  arguments.indices.contains(flagIndex + 1) else {
                throw ConfigurationError.missingUITestSurface
            }
            let rawSurface = arguments[flagIndex + 1]
            guard let surface = UITestSurface(rawValue: rawSurface) else {
                throw ConfigurationError.invalidUITestSurface(rawSurface)
            }
            return AppRuntimeConfiguration(
                applicationSupportDirectory: URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL,
                allowsScheduledUpdates: false,
                bindsGlobalHotkeys: false,
                uiTestSurface: surface
            )
        }
        #endif
        return AppRuntimeConfiguration(
            applicationSupportDirectory: defaultApplicationSupportDirectory,
            allowsScheduledUpdates: true,
            bindsGlobalHotkeys: true,
            uiTestSurface: nil
        )
    }

    static func live(processInfo: ProcessInfo = .processInfo) throws -> AppRuntimeConfiguration {
        try resolve(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaultApplicationSupportDirectory: AppPaths.defaultApplicationSupportDirectory()
        )
    }
}

@MainActor
@Observable
final class AppContainer {
    private enum UITestIsolationError: Error {
        case preferencesDomainCreationFailed(String)
    }

    enum StartupError: LocalizedError {
        case localDatabaseSetupFailed(database: URL, Error)
        case datasetSaveRecoveryFailed(Error)
        case datasetRecoveryFailed(Error)

        var errorDescription: String? {
            switch self {
            case .localDatabaseSetupFailed:
                return String(
                    localized: "ThinkAloud couldn’t open its local data. The database was left unchanged. Check that Application Support is available and writable, then retry."
                )
            case .datasetSaveRecoveryFailed:
                return String(
                    localized: "ThinkAloud couldn’t safely reconcile an interrupted dataset save. Its recovery files and audio were left unchanged. Retry; if the problem continues, restore from backup or contact support."
                )
            case .datasetRecoveryFailed:
                return String(
                    localized: "ThinkAloud couldn’t safely reconcile an interrupted dataset deletion. Its recovery files were left unchanged. Retry; if the problem continues, restore from backup or contact support."
                )
            }
        }
    }

    let runtimeConfiguration: AppRuntimeConfiguration
    let applicationSupportDirectory: URL
    let settingsDefaults: UserDefaults
    let permissions: PermissionsService
    let hotkeys: HotkeyManager
    let modelManager: ModelManager
    let llmManager: LLMManager
    let localDatabase: LocalDatabase
    let datasetStore: DatasetStore
    let dictationHistoryStore: DictationHistoryStore
    let audioFileStore: AudioFileStore
    let datasetSaveRecoveryService: DatasetSaveRecoveryService
    let datasetDeletionService: DatasetDeletionService
    let recorder: AudioRecorder
    let insertion: TextInsertionManager
    let coordinator: PopupCoordinator
    let onboardingState: OnboardingState
    private(set) var settingsWindow: SettingsWindowController!
    private(set) var datasetBrowserWindow: DatasetBrowserWindowController!
    private(set) var onboardingWindow: OnboardingWindowController!
    let hfTokenStore: HFTokenStore
    let updater: UpdaterController
    let achievements: AchievementService
    /// Owned here (not re-created per Settings render) so the toggle's SMAppService status read
    /// happens once, not on every StartupPane init.
    let launchAtLogin = LaunchAtLoginService()
    private let transientSettingsDefaultsSuiteName: String?

    convenience init() throws {
        try self.init(runtimeConfiguration: AppRuntimeConfiguration.live())
    }

    init(runtimeConfiguration: AppRuntimeConfiguration) throws {
        self.runtimeConfiguration = runtimeConfiguration
        let appSupport = runtimeConfiguration.applicationSupportDirectory
        self.applicationSupportDirectory = appSupport
        if runtimeConfiguration.uiTestSurface != nil {
            // UI automation must not read or overwrite the user's last-open Settings pane. Give
            // each isolated application-support root its own preferences domain, then remove that
            // transient domain during normal app shutdown.
            let suiteName = "cool.jacoblin.thinkaloud.ui-testing.\(appSupport.lastPathComponent)"
            guard let isolatedDefaults = UserDefaults(suiteName: suiteName) else {
                throw UITestIsolationError.preferencesDomainCreationFailed(suiteName)
            }
            self.settingsDefaults = isolatedDefaults
            self.transientSettingsDefaultsSuiteName = suiteName
        } else {
            self.settingsDefaults = .standard
            self.transientSettingsDefaultsSuiteName = nil
        }
        let modelsDir = appSupport.appendingPathComponent("models", isDirectory: true)
        // LLM weights live in a DEDICATED sibling dir (HF layout `models--*`), kept out of `models/`
        // so ModelManager.pruneRedundantHFCache() (which scans the ASR models dir) can never delete them.
        let llmDir = appSupport.appendingPathComponent("llm", isDirectory: true)
        let audioDir = appSupport.appendingPathComponent("audio", isDirectory: true)
        let dbURL = appSupport.appendingPathComponent("dataset.sqlite")

        try AppPaths.ensureDirectoryExists(appSupport)
        try AppPaths.ensureDirectoryExists(modelsDir)
        try AppPaths.ensureDirectoryExists(llmDir)
        try AppPaths.ensureDirectoryExists(audioDir)

        let permissions = PermissionsService()
        let hotkeys = HotkeyManager()
        let modelManager = try ModelManager(modelsDirectory: modelsDir)
        let llmManager = try LLMManager(cacheDirectory: llmDir)
        let localDatabase = LocalDatabase(fileURL: dbURL)
        let datasetStore = DatasetStore(database: localDatabase)
        let dictationHistoryStore = DictationHistoryStore(database: localDatabase)
        let audioFileStore = AudioFileStore(rootDirectory: audioDir)
        let datasetSaveRecoveryService = DatasetSaveRecoveryService(
            datasetStore: datasetStore,
            audioFileStore: audioFileStore,
            recoveryRoot: appSupport.appendingPathComponent(
                "Pending Dataset Saves",
                isDirectory: true
            )
        )
        let datasetDeletionService = DatasetDeletionService(
            datasetStore: datasetStore,
            audioFileStore: audioFileStore,
            recoveryRoot: appSupport.appendingPathComponent("Deleted Records", isDirectory: true)
        )
        let recorder = AudioRecorder()
        let insertion = TextInsertionManager()
        let hfTokenStore: HFTokenStore
        if runtimeConfiguration.uiTestSurface != nil {
            // A separately named item keeps UI automation from reading or mutating the user's
            // production Hugging Face credential.
            hfTokenStore = HFTokenStore(
                keychainService: "\(HFKeychain.defaultService).ui-testing.\(appSupport.lastPathComponent)"
            )
        } else {
            hfTokenStore = HFTokenStore()
        }
        let updater = UpdaterController()
        let achievements = AchievementService(
            historyStore: dictationHistoryStore,
            defaults: settingsDefaults
        )
        let onboardingState = OnboardingState()

        self.permissions = permissions
        self.hotkeys = hotkeys
        self.modelManager = modelManager
        self.llmManager = llmManager
        self.localDatabase = localDatabase
        self.datasetStore = datasetStore
        self.dictationHistoryStore = dictationHistoryStore
        self.audioFileStore = audioFileStore
        self.datasetSaveRecoveryService = datasetSaveRecoveryService
        self.datasetDeletionService = datasetDeletionService
        self.recorder = recorder
        self.insertion = insertion
        self.hfTokenStore = hfTokenStore
        self.updater = updater
        self.achievements = achievements
        self.onboardingState = onboardingState
        self.coordinator = PopupCoordinator(
            permissions: permissions,
            modelManager: modelManager,
            llmManager: llmManager,
            recorder: recorder,
            insertion: insertion,
            datasetStore: datasetStore,
            historyStore: dictationHistoryStore,
            audioFileStore: audioFileStore,
            datasetSaveRecovery: datasetSaveRecoveryService
        )
        self.settingsWindow = SettingsWindowController(container: self)
        self.datasetBrowserWindow = DatasetBrowserWindowController(container: self)
        self.onboardingWindow = OnboardingWindowController(container: self)
        self.coordinator.settingsOpener = { [weak self] category in
            self?.openSettings(to: category)
        }
        self.coordinator.onSessionSaved = { [weak self] in
            Task { @MainActor in await self?.achievements.refresh() }
        }
    }

    func openSettings(to category: SettingsCategory? = nil) {
        settingsWindow.show(category: category)
    }

    func openDatasetBrowser() {
        datasetBrowserWindow.show()
    }

    func openOnboarding() {
        onboardingWindow.show()
    }

    /// Finish or explicitly skip setup. Merely closing the window never reaches this method and
    /// therefore never marks onboarding complete.
    func finishOnboarding(as outcome: OnboardingCompletionOutcome) {
        onboardingState.markCompleted()
        if runtimeConfiguration.allowsScheduledUpdates {
            updater.start()
        }
        onboardingWindow.finish(outcome: outcome)
    }

    /// Makes every persistence dependency ready before any interactive surface is presented.
    /// A failed database setup is a launch failure, not an empty-dataset state.
    func start() async throws {
        do {
            try await datasetStore.setup()
        } catch {
            NSLog(
                "ThinkAloud: local dataset setup failed at \(datasetStore.databaseFileURL.path): \(error)"
            )
            throw StartupError.localDatabaseSetupFailed(
                database: datasetStore.databaseFileURL,
                error
            )
        }
        do {
            try await datasetSaveRecoveryService.reconcileInterruptedSaves()
        } catch {
            NSLog("ThinkAloud: interrupted dataset save reconciliation failed: \(error)")
            throw StartupError.datasetSaveRecoveryFailed(error)
        }
        do {
            try await datasetDeletionService.reconcileInterruptedDeletions()
        } catch {
            NSLog("ThinkAloud: interrupted dataset deletion reconciliation failed: \(error)")
            throw StartupError.datasetRecoveryFailed(error)
        }
        if runtimeConfiguration.bindsGlobalHotkeys {
            hotkeys.bind(handlers: .init(
                startRecording: { [weak coordinator] in coordinator?.invoke() },
                stopAndTranscribe: { [weak coordinator] in coordinator?.stopAndTranscribe() },
                insertAndSave: { [weak coordinator] in coordinator?.insertAndSave() }
            ))
        }
        if runtimeConfiguration.allowsScheduledUpdates, onboardingState.isCompleted {
            updater.start()
        }
    }

    func shutdown() {
        hotkeys.unbind()
        if let transientSettingsDefaultsSuiteName {
            settingsDefaults.removePersistentDomain(forName: transientSettingsDefaultsSuiteName)
        }
    }
}

enum AppPaths {
    enum StartupError: LocalizedError {
        case applicationSupportLookupFailed(Error)
        case directoryCreationFailed(URL, Error)

        var errorDescription: String? {
            switch self {
            case .applicationSupportLookupFailed:
                return String(
                    localized: "ThinkAloud couldn’t access Application Support. Check available storage and folder permissions, then retry."
                )
            case .directoryCreationFailed:
                return String(
                    localized: "ThinkAloud couldn’t prepare its Application Support folders. Check available storage and folder permissions, then retry."
                )
            }
        }
    }

    static func defaultApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        do {
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("ThinkAloud", isDirectory: true)
        } catch {
            NSLog("ThinkAloud: Application Support lookup failed: \(error)")
            throw StartupError.applicationSupportLookupFailed(error)
        }
    }

    static func ensureDirectoryExists(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            NSLog("ThinkAloud: directory creation failed at \(url.path): \(error)")
            throw StartupError.directoryCreationFailed(url, error)
        }
    }
}
