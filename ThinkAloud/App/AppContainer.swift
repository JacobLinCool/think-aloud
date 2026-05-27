import Foundation
import Observation

@MainActor
@Observable
final class AppContainer {
    let permissions: PermissionsService
    let hotkeys: HotkeyManager
    let modelManager: ModelManager
    let datasetStore: DatasetStore
    let audioFileStore: AudioFileStore
    let recorder: AudioRecorder
    let insertion: TextInsertionManager
    let coordinator: PopupCoordinator
    private(set) var settingsWindow: SettingsWindowController!
    private(set) var datasetBrowserWindow: DatasetBrowserWindowController!
    let hfTokenStore: HFTokenStore

    init() {
        let appSupport = AppPaths.applicationSupportDirectory()
        let modelsDir = appSupport.appendingPathComponent("models", isDirectory: true)
        let audioDir = appSupport.appendingPathComponent("audio", isDirectory: true)
        let dbURL = appSupport.appendingPathComponent("dataset.sqlite")

        AppPaths.ensureDirectoryExists(appSupport)
        AppPaths.ensureDirectoryExists(modelsDir)
        AppPaths.ensureDirectoryExists(audioDir)

        let permissions = PermissionsService()
        let hotkeys = HotkeyManager()
        let modelManager = ModelManager(modelsDirectory: modelsDir)
        let datasetStore = DatasetStore(databaseURL: dbURL)
        let audioFileStore = AudioFileStore(rootDirectory: audioDir)
        let recorder = AudioRecorder()
        let insertion = TextInsertionManager()
        let hfTokenStore = HFTokenStore()

        self.permissions = permissions
        self.hotkeys = hotkeys
        self.modelManager = modelManager
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
        self.recorder = recorder
        self.insertion = insertion
        self.hfTokenStore = hfTokenStore
        self.coordinator = PopupCoordinator(
            permissions: permissions,
            modelManager: modelManager,
            recorder: recorder,
            insertion: insertion,
            datasetStore: datasetStore,
            audioFileStore: audioFileStore
        )
        self.settingsWindow = SettingsWindowController(container: self)
        self.datasetBrowserWindow = DatasetBrowserWindowController(container: self)
        self.coordinator.settingsOpener = { [weak self] in
            self?.openSettings()
        }
    }

    func openSettings() {
        settingsWindow.show()
    }

    func openDatasetBrowser() {
        datasetBrowserWindow.show()
    }

    func start() {
        Task { @MainActor in
            do {
                try await datasetStore.setup()
            } catch {
                NSLog("DatasetStore setup failed: \(error)")
            }
        }
        hotkeys.bind(handlers: .init(
            startRecording: { [weak coordinator] in coordinator?.invoke() },
            stopAndTranscribe: { [weak coordinator] in coordinator?.stopAndTranscribe() },
            insertAndSave: { [weak coordinator] in coordinator?.insertAndSave() }
        ))
    }

    func shutdown() {
        hotkeys.unbind()
    }
}

enum AppPaths {
    static func applicationSupportDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ThinkAloud", isDirectory: true)
    }

    static func ensureDirectoryExists(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
