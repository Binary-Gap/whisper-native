import Foundation
import Combine
import AppKit
import ServiceManagement
import WhisperNativeCore

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var config: Config {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let configKey = "appConfig"

    private init() {
        defaults = .standard
        if let data = defaults.data(forKey: Self.configKey),
           let decoded = try? decoder.decode(Config.self, from: data) {
            config = decoded
        } else {
            config = .defaults
        }
    }

    public func save() {
        guard let data = try? encoder.encode(config) else { return }
        defaults.set(data, forKey: Self.configKey)

        // Sync launch-at-login state
        let launchAtLogin = config.launchAtLogin
        Task.detached {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
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
