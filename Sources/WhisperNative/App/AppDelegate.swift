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
    // (started here) and the Whisper settings page's progress bar share one downloader.
    private let modelSectionState: ModelSectionState
    private let audioRecorder: AudioRecorder
    private let whisperClient: WhisperClient
    private let textInserter: TextInserter
    private let hotkeyManager: HotkeyManager
    private let recordingIndicator: RecordingIndicator
    private let languageHUD: LanguageHUD
    private let settingsWindowController: SettingsWindowController
    private let historyWindowController: HistoryWindowController
    // Assigned right after super.init() because its onClose captures self.
    private var onboardingWindowController: OnboardingWindowController!
    private let orchestrator: Orchestrator
    private var statusBarController: StatusBarController?
    private var cancellables = Set<AnyCancellable>()
    // Lock/sleep state that keeps the start-on-voice mic closed.
    private var voiceStartScreenLocked = false
    private var voiceStartAsleep = false
    // Last model/VAD the server was (re)started with, so config saves that don't
    // touch the model don't needlessly bounce the server.
    private var activeModelPath: URL?
    private var activeVadModelPath: URL?
    // True only while a download kicked off by prepareWhisperModel (the
    // recommended model the user agreed to, or a missing VAD model) is in
    // flight. Distinguishes it from a Settings-initiated catalog download so the
    // status menu only shows "Downloading model…" for the download that's
    // blocking the daemon.
    private var awaitingFirstRunDownload = false

    // The engine the last applyEngine brought up; a declined Whisper model
    // download switches back to it.
    private var lastAppliedEngine: TranscriptionEngine = .whisper

    // True while the "Download a Whisper model?" prompt is up, so a second
    // trigger (status menu Start Server, engine switch) doesn't stack another.
    private var isAskingToDownloadModel = false

    // Set once the app starts quitting. AppKit closes open windows during
    // termination, and an onboarding window closed that way is neither a
    // Finish nor a Skip, so it leaves onboarding pending for the next launch.
    private var isTerminating = false

    // Set once the quit reply went to AppKit, so the whisper daemon bootout and
    // its timeout don't both reply.
    private var hasRepliedToTerminate = false

    // Turns SIGTERM (`pkill`, `release:install`) into a normal quit, so the
    // whisper daemon gets booted out on that path too.
    private var terminationSignalSource: DispatchSourceSignal?

    // True when the engine changed while onboarding was open; onboardingClosed
    // then runs the full engine switch instead of the plain startup.
    private var engineSwitchDeferred = false

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
            geminiBackend: GeminiBackend.shared,
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
            modelSectionState: modelSectionState,
            onOpenSettings: { [weak settingsWindowController] in
                settingsWindowController?.show()
            }
        )

        super.init()

        settingsWindowController.onToggleServer = { [weak self] in
            await self?.toggleServer()
        }

        onboardingWindowController = OnboardingWindowController(
            store: store,
            modelSectionState: modelSectionState,
            onClose: { [weak self] outcome in
                self?.onboardingClosed(outcome)
            }
        )

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

        installTerminationSignalHandler()

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
            onShowOnboarding: { [weak self] in
                self?.onboardingWindowController.show()
            },
            onToggleServer: { [weak self] in
                Task { await self?.toggleServer() }
            },
            onSelectInputDevice: { [weak self] uid in
                self?.selectInputDevice(uid)
            },
            onToggleStartOnVoice: { [weak self] in
                self?.toggleStartOnVoice()
            },
            onCheckForUpdates: {
                AppUpdater.shared.checkForUpdates()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        // Sparkle: scheduled checks plus the status menu's update item, rebuilt
        // whenever a check finds a version or the updater becomes busy/idle.
        let updater = AppUpdater.shared
        updater.start()
        updater.$availableVersion.removeDuplicates().map { _ in () }
            .merge(with: updater.$canCheckForUpdates.removeDuplicates().map { _ in () })
            .sink { [weak self] in self?.refreshStatusMenu() }
            .store(in: &cancellables)

        // History is the primary window: surface it on launch, unless onboarding
        // is pending, in which case onboarding shows instead and History follows
        // when it closes.
        let showsOnboarding = store.config.needsOnboarding
        if showsOnboarding {
            onboardingWindowController.show()
        } else {
            historyWindowController.show()
        }

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
            },
            onToggleStartOnVoice: { [weak self] in
                self?.toggleStartOnVoice()
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
        // While onboarding is open its Permissions step asks instead.
        if !showsOnboarding {
            hotkeyManager.requestAccessibilityIfNeeded()
        }

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

        // Switching engines swaps which model stays resident. A switch made in
        // onboarding applies when it closes, so picking an engine there never
        // starts a download on its own.
        lastAppliedEngine = store.config.transcriptionEngine
        store.$config
            .map(\.transcriptionEngine)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] engine in
                guard let self else { return }
                if onboardingWindowController.isShowing {
                    engineSwitchDeferred = true
                } else {
                    applyEngine(engine)
                }
            }
            .store(in: &cancellables)

        // The status menu's Accessibility warning depends on the insertion
        // strategy (only auto-paste needs the grant).
        store.$config
            .map(\.autoPasteWhenSameApp)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusMenu() }
            .store(in: &cancellables)

        // Start on voice follows its setting and reopens the mic on a new input
        // device; turning it off cancels a recording it started. Every way of
        // changing the setting (status menu, hotkey, Settings) lands here.
        // @Published emits before the new value is stored, and the handler
        // reads store.config, so it runs on the next main-queue turn.
        store.$config
            .map { ($0.startOnVoice, $0.inputDeviceUID) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.orchestrator.startOnVoiceSettingsChanged()
                self?.refreshStatusMenu()
            }
            .store(in: &cancellables)
        observeLockAndSleepForVoiceStart()

        // Voice processing takes ~0.5 s to set up, so it's ready before the
        // first hotkey dictation and rebuilt on a new input device.
        store.$config
            .map { ($0.voiceProcessing, $0.inputDeviceUID) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.orchestrator.voiceProcessingSettingsChanged() }
            .store(in: &cancellables)

        // A model download starting or finishing needs the status menu redrawn;
        // and once it finishes, the daemon that ensureWhisperServerRunning /
        // applyEngine skipped bootstrapping (missing model file) needs to start.
        // That's the download prepareWhisperModel started
        // (awaitingFirstRunDownload), or one from the Whisper page that put the
        // selected model on disk while Whisper is active and the daemon is down.
        // A download of another model while the daemon runs changes nothing
        // here (downloads never switch the model). Live percentage while
        // downloading is the Whisper settings page's job; this just flips a
        // state, so no throttling needed.
        modelSectionState.$isDownloading
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] downloading in
                guard let self else { return }
                self.refreshStatusMenu()
                guard !downloading else { return }
                let wasAwaited = self.awaitingFirstRunDownload
                self.awaitingFirstRunDownload = false
                // Clears the "Downloading…" label right away instead of after the
                // health wait below.
                if wasAwaited { self.refreshStatusMenu() }
                // A failed/cancelled download (e.g. VAD-only) can leave the model not
                // fully ready; the daemon stays down rather than crash-looping on a
                // missing file.
                guard self.store.config.transcriptionEngine == .whisper, self.whisperModelReady else { return }
                Task {
                    if !wasAwaited, await self.serverManager.healthCheck() { return }
                    self.activeModelPath = self.store.config.modelPath
                    self.activeVadModelPath = self.store.config.vadModelPath
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

        // Step 8: Ensure the selected engine is up. With onboarding open the user
        // picks the engine/model first; onboardingClosed starts it.
        if !showsOnboarding {
            startSelectedEngine()
        }

        AppLogger.shared.log(.info, "WhisperNative launched")
    }

    // Brings up whichever engine is selected. Safe to call when it's already
    // up: the whisper path health-checks first (and skips a download already in
    // flight), Parakeet's preload reuses its cached load task, and Gemini only
    // needs the daemon kept down.
    private func startSelectedEngine() {
        let engine = store.config.transcriptionEngine
        if engine == .whisper {
            ensureWhisperServerRunning()
        } else {
            applyEngine(engine)
        }
    }

    // MARK: - Onboarding

    // Finish and Skip (including the close button) both mark onboarding done,
    // then run the normal engine startup, which asks to download the
    // recommended whisper model if the user still has none. History shows
    // first so that prompt opens as a sheet on it.
    private func onboardingClosed(_ outcome: OnboardingOutcome) {
        guard !isTerminating else { return }
        store.config.onboardingCompletedVersion = Onboarding.currentVersion
        AppLogger.shared.log(.info, "Onboarding \(outcome == .finished ? "finished" : "skipped")")
        historyWindowController.show()
        // This runs from onboarding's windowWillClose, while its window still
        // counts as showing; the engine starts on the next main-queue turn,
        // once it's gone, so prepareWhisperModel doesn't defer again.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if engineSwitchDeferred {
                engineSwitchDeferred = false
                applyEngine(store.config.transcriptionEngine)
            } else {
                startSelectedEngine()
            }
        }
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
    // daemon against a missing model, so prepareWhisperModel gets it first.
    private func ensureWhisperServerRunning() {
        guard prepareWhisperModel(revertingTo: nil) == .ready else { return }
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

    /// What prepareWhisperModel left for its caller.
    private enum WhisperModelStatus {
        /// Model and VAD model are readable: the caller starts the daemon.
        case ready
        /// A repoint or download is under way; its observer starts the daemon.
        case preparing
        /// The "Download a Whisper model?" prompt is up (or onboarding is
        /// open); the caller changes nothing yet.
        case waitingForUser
    }

    // Makes sure whisper's files are on disk before the daemon starts, without
    // ever moving the Settings window to another page. A missing selection is
    // pointed at a downloaded model when there is one, and a missing ~1 MB VAD
    // model is fetched without asking. With no whisper model on disk it asks
    // before downloading the recommended one: confirming downloads and uses it
    // (progress on the Whisper page and in the status menu, a notification if
    // it finishes in the background); declining switches back to
    // `previousEngine` when the user had switched from another engine, else
    // leaves Whisper selected without a model (the Whisper page and the
    // dictation alert say so).
    private func prepareWhisperModel(revertingTo previousEngine: TranscriptionEngine?) -> WhisperModelStatus {
        if whisperModelReady { return .ready }
        // Onboarding's model step owns model choice and shows its own download
        // state; nothing is asked until it closes (onboardingClosed).
        if onboardingWindowController.isShowing {
            AppLogger.shared.log(.info, "Whisper model check deferred until onboarding closes")
            return .waitingForUser
        }
        if isAskingToDownloadModel { return .waitingForUser }
        // A download from the Whisper page is running; the $isDownloading
        // observer starts the daemon if it lands the selected model.
        guard !modelSectionState.isDownloading else { return .preparing }
        // Rescan first: the model (or VAD model) may already sit on disk — placed
        // by hand, downloaded on the Whisper page, or found after a models
        // directory change — and just needs config repointed at it, no download.
        // Clear the "active" bookkeeping first so that if reconcile does repoint
        // modelPath/vadModelPath, reloadServerForModelChange's dedup guard doesn't
        // mistake the new path for one already running and skip the reload.
        activeModelPath = nil
        activeVadModelPath = nil
        modelSectionState.refreshAndReconcile(directory: store.config.modelsDirectory, store: store, fallBackToDownloadedModel: true)
        let vadReadable = store.config.vadModelPath.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? true
        switch WhisperModelPreparation.plan(
            modelReadable: FileManager.default.isReadableFile(atPath: store.config.modelPath.path),
            vadReadable: vadReadable
        ) {
        case .ready:
            // Ready only because reconcile just repointed modelPath/vadModelPath
            // at files it found on disk; that config change already triggered
            // reloadServerForModelChange via the store.$config observer, which
            // owns the reload. Don't reload/health-check again here.
            refreshStatusMenu()
            return .preparing
        case .downloadVadOnly:
            // Model is fine, only the VAD model is missing: download just that and
            // leave modelPath (and thus the user's model choice) alone.
            AppLogger.shared.log(.info, "VAD model missing; starting VAD-only download")
            awaitingFirstRunDownload = true
            modelSectionState.downloadVadOnly(store: store)
            refreshStatusMenu()
            return .preparing
        case .askToDownloadModel:
            AppLogger.shared.log(.info, "Whisper model missing at \(store.config.modelPath.path); asking before downloading")
            askToDownloadRecommendedModel(revertingTo: previousEngine)
            return .waitingForUser
        }
    }

    // The prompt behind prepareWhisperModel's `.askToDownloadModel`: a sheet on
    // the Settings or History window when one is open (the Settings page stays
    // where it is), else a standalone alert.
    private func askToDownloadRecommendedModel(revertingTo previousEngine: TranscriptionEngine?) {
        let model = ModelManager.recommendedModel
        let revertEngine = previousEngine.flatMap { $0 == .whisper ? nil : $0 }
        let alert = NSAlert()
        alert.messageText = "Download a Whisper model?"
        let cancelOutcome = revertEngine.map { "Cancel keeps using \($0.shortName)." }
            ?? "Cancel leaves Whisper without a model, so dictation won't work until you download one there."
        alert.informativeText = "Whisper needs a model on this Mac to transcribe. Download \(model.displayName), the recommended model (\(model.approxSizeLabel))? Smaller models are on the Whisper settings page. \(cancelOutcome)"
        alert.addButton(withTitle: "Download \(model.approxSizeLabel)")
        alert.addButton(withTitle: "Cancel")
        isAskingToDownloadModel = true

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isAskingToDownloadModel = false
            guard response == .alertFirstButtonReturn else {
                AppLogger.shared.log(.info, "Whisper model download declined")
                if let revertEngine, self.store.config.transcriptionEngine == .whisper {
                    self.store.config.transcriptionEngine = revertEngine
                } else {
                    self.refreshStatusMenu()
                }
                return
            }
            AppLogger.shared.log(.info, "Whisper model download accepted: \(model.fileName)")
            Task { await ParakeetBackend.shared.unload() }
            self.awaitingFirstRunDownload = true
            self.modelSectionState.downloadDefaults(store: self.store)
            self.refreshStatusMenu()
        }

        let hostWindow = [settingsWindowController.window, historyWindowController.window]
            .compactMap { $0 }
            .first { $0.isVisible && $0.attachedSheet == nil }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handleResponse)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handleResponse(alert.runModal())
        }
    }

    // Prevent accidental termination when all windows are closed
    // (LSUIElement apps have no windows by default; this is a safety guard).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Quitting boots the whisper daemon out: its KeepAlive + RunAtLoad plist
    // would otherwise keep the model in memory, and start it at login, for an
    // app that isn't running. Other engines booted it out when they were
    // selected. A stuck launchctl delays the quit by at most 3 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        guard store.config.transcriptionEngine == .whisper else { return .terminateNow }
        Task { @MainActor in
            do {
                try await serverManager.stopServer()
            } catch {
                AppLogger.shared.log(.warning, "whisper-server bootout on quit failed: \(error)")
            }
            replyToTerminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.replyToTerminate()
        }
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // The handler runs as a main-queue block, and the main queue doesn't
        // drain while one of its blocks runs, so the quit reply (a main-actor
        // Task, a main-queue timeout) would never arrive inside it. A run loop
        // perform runs terminate outside the queue.
        source.setEventHandler {
            RunLoop.main.perform { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignalSource = source
    }

    // Re-open brings onboarding forward while it's open, otherwise the primary
    // History window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if onboardingWindowController.isShowing {
            onboardingWindowController.window?.makeKeyAndOrderFront(nil)
        } else if !hasVisibleWindows {
            historyWindowController.show()
        }
        return true
    }

    // Returning focus to the app (e.g. after granting Accessibility in System
    // Settings) re-checks the modifier-key tap so the menu warning clears without
    // a relaunch.
    func applicationDidBecomeActive(_ notification: Notification) {
        let wasWarning = accessibilityWarning
        hotkeyManager.refreshModifierTap()
        guard wasWarning != accessibilityWarning else { return }
        refreshStatusMenu()
    }

    /// Status menu Accessibility warning: auto-paste or the single-key toggle
    /// can't work until Accessibility is granted.
    private var accessibilityWarning: Bool {
        InsertionPlan.accessibilityWarningShown(
            autoPasteWhenSameApp: store.config.autoPasteWhenSameApp,
            accessibilityGranted: hotkeyManager.accessibilityGranted,
            modifierToggleAvailable: hotkeyManager.modifierToggleAvailable
        )
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
    /// percentage; the Whisper settings page has the live progress).
    /// Keyed on awaitingFirstRunDownload, not modelSectionState.isDownloading, so
    /// a Settings-initiated catalog download (server still running the old model)
    /// doesn't get mislabeled as blocking the daemon. "None downloaded" when the
    /// selected model isn't on disk (a declined download).
    private var statusMenuModelLabel: String {
        if awaitingFirstRunDownload { return "Downloading…" }
        guard FileManager.default.isReadableFile(atPath: store.config.modelPath.path) else { return "None downloaded" }
        return store.config.selectedModelName
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
            accessibilityWarning: accessibilityWarning,
            downloadingModel: awaitingFirstRunDownload,
            whisperEngineActive: store.config.transcriptionEngine == .whisper,
            startOnVoice: store.config.startOnVoice,
            update: updateMenuState
        )
    }

    private var updateMenuState: UpdateMenuState {
        let updater = AppUpdater.shared
        guard updater.isEnabled else { return .hidden }
        if let version = updater.availableVersion { return .available(version: version) }
        return .idle(canCheck: updater.canCheckForUpdates)
    }

    // MARK: - Start on voice

    // Closes the start-on-voice mic while the screen is locked or the Mac sleeps
    // (nobody is dictating, and a voice in the room would record into a locked
    // session), and reopens it after, which also recovers a capture that sleep
    // left dead.
    private func observeLockAndSleepForVoiceStart() {
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setVoiceStartBlocker(screenLocked: true) }
        }
        distributedCenter.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setVoiceStartBlocker(screenLocked: false) }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setVoiceStartBlocker(asleep: true) }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setVoiceStartBlocker(asleep: false) }
        }
    }

    private func setVoiceStartBlocker(screenLocked: Bool? = nil, asleep: Bool? = nil) {
        if let screenLocked { voiceStartScreenLocked = screenLocked }
        if let asleep { voiceStartAsleep = asleep }
        orchestrator.voiceStartSuspended = voiceStartScreenLocked || voiceStartAsleep
    }

    // MARK: - Language cycle (hotkey)

    // Advances the transcription language through the active languages and
    // confirms it with the HUD. The language is read at request time, so cycling
    // mid-recording applies to the transcription currently being recorded.
    private func cycleLanguage() {
        let language = Language.next(after: store.config.selectedLanguage, in: store.config.activeLanguages)
        store.config.selectedLanguage = language
        languageHUD.show(code: language.displayCode, name: language.displayName)
        AppLogger.shared.log(.info, "Language cycled to \(language.rawValue)")
    }

    // MARK: - Start on voice toggle (status menu and hotkey)

    // Flips the setting and confirms the new state with the HUD. The mic
    // opening/closing and the status menu check mark follow from the
    // startOnVoice config observer, the same path the Settings toggle takes;
    // turning it off there also cancels a recording Start on voice started. A
    // hotkey recording keeps going, so the HUD is what shows the click took effect.
    private func toggleStartOnVoice() {
        store.config.startOnVoice.toggle()
        let isOn = store.config.startOnVoice
        languageHUD.show(code: isOn ? "ON" : "OFF", name: "Auto-start")
        AppLogger.shared.log(.info, "Start on voice turned \(isOn ? "on" : "off")")
    }

    // MARK: - Engine switch (config observer)

    // Parakeet runs in-process and both Gemini engines in the cloud, so
    // selecting any of them boots the whisper daemon out to free its memory
    // (KeepAlive would respawn it otherwise); the Gemini engines also unload
    // Parakeet. Switching back to whisper
    // unloads Parakeet and re-bootstraps whisper with the current model.
    private func applyEngine(_ engine: TranscriptionEngine) {
        AppLogger.shared.log(.info, "Transcription engine: \(engine.rawValue)")
        let previousEngine = lastAppliedEngine
        lastAppliedEngine = engine
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
            case .gemini, .geminiLive:
                do {
                    try await serverManager.stopServer()
                } catch {
                    AppLogger.shared.log(.warning, "whisper-server bootout for Gemini: \(error)")
                }
                await ParakeetBackend.shared.unload()
                refreshStatusMenu()
            case .whisper:
                // Fresh machine / model (or VAD) deleted out from under the
                // config: reload would crash-loop the daemon against a missing
                // model, so prepareWhisperModel gets it first (the $isDownloading
                // or modelPath observer bootstraps once it lands). Checked before
                // unloading Parakeet: while the download prompt is up the
                // previous engine stays intact, so declining can switch back to
                // it (accepting unloads Parakeet).
                let modelStatus = prepareWhisperModel(revertingTo: previousEngine)
                guard modelStatus != .waitingForUser else { return }
                await ParakeetBackend.shared.unload()
                guard modelStatus == .ready else { return }
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
        // The daemon is down while another engine is selected; applyEngine picks up the
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

    // MARK: - Server toggle (status menu and Settings > Whisper)

    private func toggleServer() async {
        // The menu item and the Whisper page button are disabled while another engine is selected, but
        // guard here too since those engines leave no whisper model requirement to
        // start a (possibly 1.6 GB) download for a daemon that won't be used.
        guard store.config.transcriptionEngine == .whisper else { return }
        let running = await serverManager.isRunning
        // Starting with no readable model would just crash-loop the daemon;
        // route through prepareWhisperModel (asks before a model download) instead.
        if !running, prepareWhisperModel(revertingTo: nil) != .ready {
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

    // MARK: - Microphone selection (called from status menu)

    private func selectInputDevice(_ uid: String?) {
        store.config.inputDeviceUID = uid
        Task {
            let running = await serverManager.isRunning
            updateStatusMenu(serverRunning: running)
        }
    }
}
