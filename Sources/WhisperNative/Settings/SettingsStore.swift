import Foundation
import Combine
import AppKit
import ServiceManagement
import WhisperNativeCore

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    // Every change path (Settings, status menu, hotkey) lands here, so this is
    // where voice processing and Start on voice are kept exclusive.
    @Published public var config: Config {
        didSet {
            let resolved = VoiceProcessingPolicy.resolveExclusive(previous: oldValue, current: config)
            if let turnedOff = resolved.turnedOff {
                config = resolved.config
                AppLogger.shared.log(.info, "Turned off \(turnedOff) to keep voice processing and Start on voice exclusive")
            }
            if resolved.turnedOff != nil
                || oldValue.voiceProcessing != config.voiceProcessing
                || oldValue.startOnVoice != config.startOnVoice {
                lastExclusiveTurnOff = resolved.turnedOff
            }
            save()
        }
    }

    /// The setting the last voice processing / Start on voice change turned
    /// off, shown under it in Settings until either setting changes again.
    @Published public private(set) var lastExclusiveTurnOff: ExclusiveMicSetting?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let configKey = "appConfig"

    private init() {
        defaults = .standard
        if let data = defaults.data(forKey: Self.configKey),
           let decoded = try? decoder.decode(Config.self, from: data) {
            config = VoiceProcessingPolicy.resolveExclusive(previous: decoded, current: decoded).config
        } else {
            config = .defaults
        }
    }

    public func save() {
        guard let data = try? encoder.encode(config) else { return }
        defaults.set(data, forKey: Self.configKey)

        // Sync launch-at-login state, touching SMAppService only when it differs
        // (unregistering a never-registered app throws "Operation not permitted")
        let launchAtLogin = config.launchAtLogin
        Task.detached {
            let service = SMAppService.mainApp
            do {
                if launchAtLogin {
                    if service.status != .enabled {
                        try service.register()
                    }
                } else if service.status == .enabled || service.status == .requiresApproval {
                    try await service.unregister()
                }
            } catch {
                AppLogger.shared.log(.warning, "SMAppService toggle failed: \(error)")
            }
        }
    }

    public func reset() {
        config = .defaults
    }

    // MARK: - Server health

    public func checkServerAvailable() async -> Bool {
        guard let url = URL(string: "http://\(Constants.serverHost):\(Constants.serverPort)") else { return false }
        let client = WhisperClient(serverBaseURL: url)
        return await client.isAvailable()
    }
}
