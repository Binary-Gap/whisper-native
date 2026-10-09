import AppKit
import Combine
import Sparkle
import WhisperNativeCore

/// Sparkle updater shared by the status menu and Settings > General. Checks the
/// appcast on Sparkle's schedule (daily) and installs after the user clicks
/// Install in Sparkle's update window, or on its own at the next quit while
/// "Install updates automatically" is on. A scheduled check found while
/// the app is in the background is shown gently: the menu item and the
/// Settings line name the version, and clicking either opens the window.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// Dev builds read the feed from this UserDefaults key, for testing the
    /// update flow against a local appcast; without it they have no updater.
    private static let devFeedURLDefaultsKey = "updateFeedURL"

    /// The version a check found and the user hasn't installed yet.
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?

    private let feedURL: URL?
    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        if Constants.isDevBuild {
            feedURL = UserDefaults.standard.string(forKey: Self.devFeedURLDefaultsKey).flatMap(URL.init(string:))
        } else {
            feedURL = Constants.updateFeedURL
        }
        super.init()
    }

    /// False in a dev build without a test feed: Settings says so and the
    /// status menu leaves the item out.
    var isEnabled: Bool { controller != nil }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    /// Same setting as the checkbox in Sparkle's update window. Only takes
    /// effect while automatic checks are on.
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    /// Starts Sparkle (its first scheduled check included). Call once at launch.
    func start() {
        guard controller == nil, feedURL != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .sink { [weak self] value in self?.lastCheckDate = value }
            .store(in: &cancellables)
        // Ticking the checkbox in Sparkle's window updates the Settings toggle.
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Opens Sparkle's window: the found update with its Install button, or a
    /// fresh check when none is pending.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

// MARK: - SPUUpdaterDelegate

extension AppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL?.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
    }

    // Sparkle also ends a check that found nothing through here; only real
    // failures get logged.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { return }
        AppLogger.shared.log(.warning, "Update check failed: \(error.localizedDescription)")
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    // A menu-bar app has no window to come back to, so a scheduled update found
    // while the user works elsewhere waits in the menu and Settings instead of
    // popping a window behind their apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        availableVersion = update.displayVersionString
    }
}
