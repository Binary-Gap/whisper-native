import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import WhisperNativeCore

// AppDelegate is the root owner of all module instances.
// It lives for the full application lifetime (retained by NSApplication).
// @MainActor isolation matches NSApplicationDelegate contract on macOS 14+.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Module instances

    private let store: SettingsStore
    private let serverManager: WhisperServerManager
    // Owns the whisper model download so a first-run/engine-switch download
    // (started here) and the General tab's progress bar share one downloader.
    private let modelSectionState: ModelSectionState
    private let audioRecorder: AudioRecorder
    private let whisperClient: WhisperClient
    private let textInserter: TextInserter
    private let hotkeyManager: HotkeyManager
    private let recordingIndicator: RecordingIndicator
    private let languageHUD: LanguageHUD
    private let settingsWindowController: SettingsWindowController
    private let historyWindowController: HistoryWindowController
    private let orchestrator: Orchestrator
    private var statusBarController: StatusBarController?
    private var cancellables = Set<AnyCancellable>()
    // Last model/VAD the server was (re)started with, so config saves that don't
    // touch the model don't needlessly bounce the server.
    private var activeModelPath: URL?
    private var activeVadModelPath: URL?
    // True only while a download kicked off by startFirstRunModelDownload is in
    // flight. Distinguishes it from a Settings-initiated catalog download so the
    // $isDownloading observer only bootstraps the server (and the status menu
    // only shows "Downloading model…") for the download that's blocking the
    // daemon, not for a background model switch while the server already runs.
    private var awaitingFirstRunDownload = false

    // MARK: - Init

    override init() {
        // Step 1: SettingsStore loads (or writes defaults to) UserDefaults.
        store = SettingsStore.shared

        // Step 2: Instantiate all module objects.
        serverManager = WhisperServerManager(config: store.config)
        modelSectionState = ModelSectionState()
        audioRecorder = AudioRecorder()
        whisperClient = WhisperClient()
        textInserter = TextInserter()
        recordingIndicator = RecordingIndicator()
        languageHUD = LanguageHUD()
        hotkeyManager = HotkeyManager()

        // Step 3: Instantiate Orchestrator, injecting via protocols.
        orchestrator = Orchestrator(
            store: store,
            serverManager: serverManager,
            audioRecorder: audioRecorder,
            backend: whisperClient,
            parakeetBackend: ParakeetBackend.shared,
            textInserter: textInserter,
            indicator: recordingIndicator,
            liveTranscriptPill: LiveTranscriptPill(),
            modelSectionState: modelSectionState
        )

        // Step 5: Settings + History window controllers.
        let settingsWindowController = SettingsWindowController(store: store, hotkeyManager: hotkeyManager, modelSectionState: modelSectionState)
        self.settingsWindowController = settingsWindowController
        historyWindowController = HistoryWindowController(
            store: store,
            onOpenSettings: { [weak settingsWindowController] in
                settingsWindowController?.show()
            }
        )

        super.init()

        // Step 4: Wire AudioRecorder failure callback to Orchestrator.
        // (Cannot be done before super.init() in Swift; audioRecorder.onRecordingFailed
        // is a mutable property set after init.)
        audioRecorder.onRecordingFailed = { [weak orchestrator] error in
            Task { @MainActor in
                orchestrator?.handleRecordingFailed(error)
            }
        }

        // Attach the indicator to the recorder so timeout can set recordingTimedOut.
        audioRecorder.indicator = recordingIndicator

        // Drive the indicator glow from live mic input level.
        audioRecorder.onLevelUpdate = { [weak recordingIndicator] level in
            Task { @MainActor in
                recordingIndicator?.updateLevel(level)
            }
        }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install a minimal main menu so windows show the app name in the macOS
        // menu bar and text fields get standard Edit shortcuts (this agent app
        // has no menu by default).
        MainMenu.install()

        // Apply the Dock-icon baseline (menu-bar-only vs .regular) from config.
        SettingsWindowController.applyBaselineActivationPolicy(store.config)

        // Step 6: Build status bar.
        statusBarController = StatusBarController(
            onShowSettings: { [weak self] in
                self?.settingsWindowController.show()
            },
            onShowHistory: { [weak self] in
                self?.historyWindowController.show()
            },
            onToggleServer: { [weak self] in
                self?.toggleServer()
            },
            onSelectInputDevice: { [weak self] uid in
                self?.selectInputDevice(uid)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        // History is the primary window: surface it on launch.
        historyWindowController.show()

        // Step 7: Register hotkeys.
        hotkeyManager.register(
            onToggle: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.orchestrator.handleToggle()
                }
            },
            onCancel: { [weak self] in
                self?.orchestrator.handleCancel()
            },
            onPasteLast: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.orchestrator.handlePasteLast()
                }
            },
            onCycleLanguage: { [weak self] in
                self?.cycleLanguage()
            }
        )

        // Gate the cancel hotkey on the active recording/transcription state so
        // the key passes through to focused apps when nothing is in flight.
        orchestrator.onActiveStateChanged = { [weak self] active in
            self?.hotkeyManager.setCancelHotkeyEnabled(active)
        }

        // The hotkey manager polls for the Accessibility grant and self-heals the
        // global modifier tap once trusted (a freshly notarized build always starts
        // ungranted since TCC keys the grant to the code signature). Clear the
        // status-menu warning when that happens, no relaunch needed.
        hotkeyManager.onAvailabilityChanged = { [weak self] in
            self?.refreshStatusMenu()
        }

        // A fresh (re)install always starts ungranted because TCC keys the grant to
        // the code signature. Surface the system Accessibility prompt on launch when
        // a modifier key is configured but untrusted, so the user isn't left with a
        // silently dead hotkey. The self-heal poll then installs the tap once granted.
        hotkeyManager.requestAccessibilityIfNeeded()

        // Sync the cancel shortcut binding to the persisted CancelKey choice
        // (Escape can't be shown by the recorder, so the picker owns it).
        if store.config.cancelKey == .escape {
            KeyboardShortcuts.setShortcut(.init(.escape), for: .cancelTranscription)
        }
        // setShortcut re-registers (and thus re-enables) the shortcut, undoing the
        // disable in register(). Re-assert the gated-closed state so the cancel key
        // passes through to focused apps until a recording/transcription starts.
        hotkeyManager.setCancelHotkeyEnabled(false)

        // Keep the menu-bar language code in sync with the config, so it reflects
        // both the hotkey cycle and the Settings picker.
        statusBarController?.updateLanguage(store.config.selectedLanguage)
        store.$config
            .map(\.selectedLanguage)
            .removeDuplicates()
            .sink { [weak self] language in
                self?.statusBarController?.updateLanguage(language)
            }
            .store(in: &cancellables)

        // Reload the server whenever the selected model or VAD model changes.
        activeModelPath = store.config.modelPath
        activeVadModelPath = store.config.vadModelPath
        store.$config
            .map { ($0.modelPath, $0.vadModelPath) }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] modelPath, vadModelPath in
                self?.reloadServerForModelChange(modelPath: modelPath, vadModelPath: vadModelPath)
            }
            .store(in: &cancellables)

        // Switching engines swaps which model stays resident.
        store.$config
            .map(\.transcriptionEngine)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] engine in
                self?.applyEngine(engine)
            }
            .store(in: &cancellables)

        // A first-run/engine-switch model download starting or finishing needs the
        // status menu redrawn; and once it finishes, the daemon that
        // ensureWhisperServerRunning/applyEngine skipped bootstrapping (missing
        // model file) needs to actually start. This only acts on the download
        // startFirstRunModelDownload started (awaitingFirstRunDownload): a
        // Settings-initiated catalog download fires the same $isDownloading
        // publisher but must not bootstrap or reload anything here — its own
        // modelPath observer (below) already handles that. Live percentage while
        // downloading is the General tab's job (opened below); this just flips a
        // state, so no throttling needed.
        modelSectionState.$isDownloading
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] downloading in
                guard let self else { return }
                self.refreshStatusMenu()
                guard self.awaitingFirstRunDownload, !downloading else { return }
                self.awaitingFirstRunDownload = false
                // Clears the "Downloading…" label right away instead of after the
                // health wait below.
                self.refreshStatusMenu()
                // A failed/cancelled download (e.g. VAD-only) can leave the model not
                // fully ready; the daemon stays down rather than crash-looping on a
                // missing file.
                guard self.store.config.transcriptionEngine == .whisper, self.whisperModelReady else { return }
                self.activeModelPath = self.store.config.modelPath
                self.activeVadModelPath = self.store.config.vadModelPath
                Task {
                    do {
                        try await self.serverManager.reload(modelPath: self.store.config.modelPath, vadModelPath: self.store.config.vadModelPath)
                    } catch {
                        AppLogger.shared.log(.error, "Server bootstrap after first-run download failed: \(error)")
                    }
                    let running = await self.waitForHealthy()
                    self.updateStatusMenu(serverRunning: running)
                }
            }
            .store(in: &cancellables)

        // Step 8: Ensure the selected engine is up.
        if store.config.transcriptionEngine == .parakeet {
            applyEngine(.parakeet)
        } else {
            ensureWhisperServerRunning()
        }

        AppLogger.shared.log(.info, "WhisperNative launched")
    }

    // True once both the selected whisper model and its VAD model (when one is
    // configured) are readable on disk. Missing either would bootstrap the
    // KeepAlive daemon into a crash loop (whisper-server exits immediately on a
    // bad -m/-vm path), so both first-run and engine-switch treat either as
    // needing the download.
    private var whisperModelReady: Bool {
        guard FileManager.default.isReadableFile(atPath: store.config.modelPath.path) else { return false }
        guard let vadPath = store.config.vadModelPath else { return true }
        return FileManager.default.isReadableFile(atPath: vadPath.path)
    }

    // If a health check fails (fresh boot, stale/booted-out plist), regenerate
    // the plist and bootstrap it. On a fresh machine the configured model file
    // doesn't exist yet: bootstrapping anyway would crash-loop the KeepAlive
    // daemon against a missing model, so download it first instead.
    private func ensureWhisperServerRunning() {
        guard whisperModelReady else {
            startFirstRunModelDownload()
            return
        }
        Task {
            var running = await serverManager.healthCheck()
            if !running {
                do {
                    // reload (not startServer) so this always installs the plist
                    // against the CURRENT store.config rather than whatever config
                    // WhisperServerManager was constructed with at launch.
                    try await serverManager.reload(modelPath: store.config.modelPath, vadModelPath: store.config.vadModelPath)
                    activeModelPath = store.config.modelPath
                    activeVadModelPath = store.config.vadModelPath
                    running = await waitForHealthy()
                } catch {
                    AppLogger.shared.log(.error, "Server autostart failed: \(error)")
                }
            }
            updateStatusMenu(serverRunning: running)
        }
    }

    // Model load takes a few seconds after a reload; poll until healthy rather
    // than judging the daemon "Stopped" off a single check right after asking it
    // to start. Shared by server autostart and the first-run download completion
    // path, which both reload the daemon and then need to know when it's up.
    private func waitForHealthy() async -> Bool {
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await serverManager.healthCheck() { return true }
        }
        return false
    }

    // Kicks off the shared model downloader (reused, not duplicated, so the
    // General tab's progress bar reflects it) and surfaces progress to the user:
    // opens Settings on the General tab and flips the status menu to a
    // "Downloading model…" state. The $isDownloading observer above bootstraps
    // the server once the download lands.
    private func startFirstRunModelDownload() {
        guard !modelSectionState.isDownloading else { return }
        // Rescan first: the model (or VAD model) may already sit on disk — placed
        // by hand, left over from an engine switch, or found after a models
        // directory change — and just needs config repointed at it, no download.
        // Clear the "active" bookkeeping first so that if reconcile does repoint
        // modelPath/vadModelPath, reloadServerForModelChange's dedup guard doesn't
        // mistake the new path for one already running and skip the reload.
        activeModelPath = nil
        activeVadModelPath = nil
        modelSectionState.refreshAndReconcile(directory: store.config.modelsDirectory, store: store)
        guard !whisperModelReady else {
            // whisperModelReady flipped true only because reconcile just repointed
            // modelPath/vadModelPath at files it found on disk; that config change
            // already triggered reloadServerForModelChange via the store.$config
            // observer, which owns the reload. Don't reload/health-check again here.
            refreshStatusMenu()
            return
        }
        awaitingFirstRunDownload = true
        if FileManager.default.isReadableFile(atPath: store.config.modelPath.path) {
            // Model is fine, only the VAD model is missing: download just that and
            // leave modelPath (and thus the user's model choice) alone.
            AppLogger.shared.log(.info, "VAD model missing; starting VAD-only download")
            modelSectionState.downloadVadOnly(store: store)
        } else {
            AppLogger.shared.log(.info, "Whisper model missing at \(store.config.modelPath.path); starting first-run download")
            modelSectionState.downloadDefaults(store: store)
        }
        settingsWindowController.showGeneralTab()
        refreshStatusMenu()
    }

    // Prevent accidental termination when all windows are closed
    // (LSUIElement apps have no windows by default; this is a safety guard).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Re-open brings up the primary History window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            historyWindowController.show()
        }
        return true
    }

    // Returning focus to the app (e.g. after granting Accessibility in System
    // Settings) re-checks the modifier-key tap so the menu warning clears without
    // a relaunch.
    func applicationDidBecomeActive(_ notification: Notification) {
        let wasAvailable = hotkeyManager.modifierToggleAvailable
        hotkeyManager.refreshModifierTap()
        guard wasAvailable != hotkeyManager.modifierToggleAvailable else { return }
        refreshStatusMenu()
    }

    /// Rebuild the status-bar menu from current server/config/permission state.
    private func refreshStatusMenu() {
        Task {
            let running = await serverManager.isRunning
            updateStatusMenu(serverRunning: running)
        }
    }

    /// The model name shown in the status menu: the active model while idle, or a
    /// placeholder while the first-run/engine-switch download is in flight (the
    /// menu isn't live-updated while open, so it shows a state, not a frozen
    /// percentage — the General tab, opened alongside it, has the live progress).
    /// Keyed on awaitingFirstRunDownload, not modelSectionState.isDownloading, so
    /// a Settings-initiated catalog download (server still running the old model)
    /// doesn't get mislabeled as blocking the daemon.
    private var statusMenuModelLabel: String {
        awaitingFirstRunDownload ? "Downloading…" : store.config.selectedModelName
    }

    /// Shared tail end of every server/config/download state change: rebuilds
    /// the status-bar menu from the current config, download and permission
    /// state plus the caller's freshly-checked server state.
    private func updateStatusMenu(serverRunning: Bool) {
        statusBarController?.updateMenu(
            serverRunning: serverRunning,
            modelName: statusMenuModelLabel,
            inputDevices: AudioRecorder.listInputDevices(),
            selectedInputDeviceUID: store.config.inputDeviceUID,
            accessibilityWarning: !hotkeyManager.modifierToggleAvailable,
            downloadingModel: awaitingFirstRunDownload,
            whisperEngineActive: store.config.transcriptionEngine == .whisper
        )
    }

    // MARK: - Language cycle (hotkey)

    // Advances the transcription language through the user's cycle list and
    // confirms it with the HUD. The language is read at request time, so cycling
    // mid-recording applies to the transcription currently being recorded.
    private func cycleLanguage() {
        let language = Language.next(after: store.config.selectedLanguage, in: store.config.cycleLanguages)
        store.config.selectedLanguage = language
        languageHUD.show(code: language.displayCode, name: language.displayName)
        AppLogger.shared.log(.info, "Language cycled to \(language.rawValue)")
    }

    // MARK: - Engine switch (config observer)

    // Parakeet runs in-process, so selecting it boots the whisper daemon out to
    // free its memory (KeepAlive would respawn it otherwise); switching back
    // unloads Parakeet and re-bootstraps whisper with the current model.
    private func applyEngine(_ engine: TranscriptionEngine) {
        AppLogger.shared.log(.info, "Transcription engine: \(engine.rawValue)")
        Task {
            switch engine {
            case .parakeet:
                // Unconditional: a daemon still loading its model fails the
                // health check but is loaded in launchd all the same.
                do {
                    try await serverManager.stopServer()
                } catch {
                    AppLogger.shared.log(.warning, "whisper-server bootout for Parakeet: \(error)")
                }
                do {
                    try await ParakeetBackend.shared.preload()
                } catch {
                    AppLogger.shared.log(.error, "Parakeet preload failed: \(error)")
                }
                refreshStatusMenu()
            case .whisper:
                await ParakeetBackend.shared.unload()
                // Fresh machine / model (or VAD) deleted out from under the
                // config: reload would crash-loop the daemon against a missing
                // model, so download it first instead (the $isDownloading
                // observer bootstraps once it lands).
                guard whisperModelReady else {
                    startFirstRunModelDownload()
                    return
                }
                activeModelPath = store.config.modelPath
                activeVadModelPath = store.config.vadModelPath
                do {
                    try await serverManager.reload(modelPath: store.config.modelPath, vadModelPath: store.config.vadModelPath)
                } catch {
                    AppLogger.shared.log(.error, "Restarting whisper-server failed: \(error)")
                }
                // Model load takes a few seconds after a reload; poll rather than
                // judge the daemon "Stopped" off a single check right after restart.
                updateStatusMenu(serverRunning: await waitForHealthy())
            }
        }
    }

    // MARK: - Model reload (config observer)

    // Restarts the whisper-server against the newly selected model/VAD. Skips the
    // reload if the model file is missing (e.g. a picker briefly points at a path
    // being downloaded) to avoid bootstrapping the server into a crash loop.
    private func reloadServerForModelChange(modelPath: URL, vadModelPath: URL?) {
        // The daemon is down while Parakeet is selected; applyEngine picks up the
        // new model when switching back.
        guard store.config.transcriptionEngine == .whisper else { return }
        // A first-run download sets modelPath/vadModelPath right before flipping
        // isDownloading to false, which fires this observer too; the
        // $isDownloading observer in applicationDidFinishLaunching owns that
        // reload, so skip it here to avoid reloading the daemon twice.
        guard !awaitingFirstRunDownload else { return }
        guard modelPath != activeModelPath || vadModelPath != activeVadModelPath else { return }
        guard FileManager.default.isReadableFile(atPath: modelPath.path) else {
            AppLogger.shared.log(.warning, "Skipping server reload: model not readable at \(modelPath.path)")
            return
        }
        if let vadModelPath, !FileManager.default.isReadableFile(atPath: vadModelPath.path) {
            AppLogger.shared.log(.warning, "Skipping server reload: VAD model not readable at \(vadModelPath.path)")
            return
        }
        activeModelPath = modelPath
        activeVadModelPath = vadModelPath
        Task {
            do {
                try await serverManager.reload(modelPath: modelPath, vadModelPath: vadModelPath)
            } catch {
                AppLogger.shared.log(.error, "Server reload after model change failed: \(error)")
            }
            // Model load takes a few seconds after a reload; poll rather than judge
            // the daemon "Stopped" off a single check right after asking it to start.
            updateStatusMenu(serverRunning: await waitForHealthy())
        }
    }

    // MARK: - Server toggle (called from status menu)

    private func toggleServer() {
        // The menu already disables this item while Parakeet is selected, but
        // guard here too since Parakeet leaves no whisper model requirement to
        // start a (possibly 1.6 GB) download for a daemon that won't be used.
        guard store.config.transcriptionEngine == .whisper else { return }
        Task {
            let running = await serverManager.isRunning
            // Starting with no readable model would just crash-loop the daemon;
            // route through the same first-run download flow instead.
            if !running, !whisperModelReady {
                startFirstRunModelDownload()
                return
            }
            do {
                if running {
                    try await serverManager.stopServer()
                } else {
                    // reload (not startServer) so this installs against the
                    // CURRENT store.config rather than WhisperServerManager's
                    // launch-time snapshot.
                    try await serverManager.reload(modelPath: store.config.modelPath, vadModelPath: store.config.vadModelPath)
                    activeModelPath = store.config.modelPath
                    activeVadModelPath = store.config.vadModelPath
                }
            } catch {
                AppLogger.shared.log(.error, "Server toggle failed: \(error)")
            }
            // Refresh menu regardless of success/failure.
            let nowRunning = await serverManager.isRunning
            updateStatusMenu(serverRunning: nowRunning)
        }
    }

    // MARK: - Microphone selection (called from status menu)

    private func selectInputDevice(_ uid: String?) {
        store.config.inputDeviceUID = uid
        Task {
            let running = await serverManager.isRunning
            updateStatusMenu(serverRunning: running)
        }
    }
}
