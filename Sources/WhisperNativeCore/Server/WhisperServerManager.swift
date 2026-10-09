import Foundation

public protocol WhisperServerManaging: AnyObject, Sendable {
    var isRunning: Bool { get async }
    func startServer() async throws
    func stopServer() async throws
    func healthCheck() async -> Bool
    func loadModel(at path: URL) async throws
    func reload(modelPath: URL, vadModelPath: URL?) async throws
    func generateLaunchdPlist(modelPath: URL, vadModelPath: URL?) -> String
    func installLaunchdPlist(modelPath: URL, vadModelPath: URL?) async throws
}

public actor WhisperServerManager: WhisperServerManaging {

    private let config: Config
    private let launchdManager: LaunchdManager
    private let session: URLSession
    private let decoder = JSONDecoder()

    /// Resolved path to the whisper-server binary.
    private let binaryPath: String

    public init(config: Config) {
        self.config = config
        self.launchdManager = LaunchdManager()

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1
        sessionConfig.timeoutIntervalForResource = 1
        self.session = URLSession(configuration: sessionConfig)

        self.binaryPath = Self.resolveBinaryPath()
    }

    /// Resolves the whisper-server binary. Order: explicit env override, then the
    /// copy bundled inside the .app (Contents/MacOS), then the dev build tree
    /// under external/whisper.cpp for `xcodebuild`-from-source runs.
    private static func resolveBinaryPath() -> String {
        if let envPath = ProcessInfo.processInfo.environment["WHISPER_SERVER_BINARY"],
           !envPath.isEmpty {
            return envPath
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-server")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        #if DEBUG
        // Dev fallback: binary produced by `mise run whisper:build`. Resolves to the
        // checkout this file was compiled from, by walking up from #filePath to the
        // repo root (Sources/WhisperNativeCore/Server/ -> repo root is 4 levels up).
        // Debug only, so Release binaries don't embed the checkout path.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = repoRoot
            .appendingPathComponent("external/whisper.cpp/build/bin/whisper-server")
            .path
        return devPath
        #else
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/whisper-server")
            .path
        #endif
    }

    // MARK: - WhisperServerManaging

    public var isRunning: Bool {
        get async {
            await healthCheck()
        }
    }

    /// Performs a GET /health with a 1-second timeout.
    /// Returns true only when response is 200 and body contains {"status":"ok"}.
    public func healthCheck() async -> Bool {
        do {
            let (data, response) = try await session.data(from: Constants.serverHealthURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            // Accept {"status":"ok"} — reject {"status":"loading model"}
            if let body = try? decoder.decode([String: String].self, from: data),
               body["status"] == "ok" {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// Regenerates the plist (so the app always owns its config) then bootstraps.
    public func startServer() async throws {
        // Always rewrite the plist: a stale on-disk copy (e.g. left by an older
        // install) would otherwise win silently and point logs/tmp at the wrong dirs.
        // installLaunchdPlist handles the bootout/bootstrap if already loaded.
        try await installLaunchdPlist(modelPath: config.modelPath, vadModelPath: config.vadModelPath)
        AppLogger.shared.log(.info, "whisper-server bootstrapped via launchctl")
    }

    /// Bootouts and disables the service via launchctl.
    public func stopServer() async throws {
        try await launchdManager.bootout()
        AppLogger.shared.log(.info, "whisper-server booted out via launchctl")
    }

    /// Hot-swaps the model via POST /load.
    /// Only call on explicit user model change — always reloads full model from disk.
    public func loadModel(at path: URL) async throws {
        var request = URLRequest(url: Constants.serverLoadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60

        var form = MultipartFormData()
        form.addTextField(name: "model", value: path.path)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalize()

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnhealthy("no HTTP response from /load")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppError.serverUnhealthy("POST /load returned \(http.statusCode): \(body)")
        }
        AppLogger.shared.log(.info, "Model loaded: \(path.lastPathComponent)")
    }

    /// Restarts the server against a new model/VAD by rewriting the plist and
    /// re-bootstrapping. Use when the user changes the selected model in Settings.
    public func reload(modelPath: URL, vadModelPath: URL?) async throws {
        try await installLaunchdPlist(modelPath: modelPath, vadModelPath: vadModelPath)
        AppLogger.shared.log(.info, "whisper-server reloaded with model \(modelPath.lastPathComponent)")
    }

    /// Generates the launchd plist XML string with the correct ProgramArguments.
    public nonisolated func generateLaunchdPlist(modelPath: URL, vadModelPath: URL?) -> String {
        ServerPlist.generate(
            binaryPath: binaryPath,
            modelPath: modelPath,
            vadModelPath: vadModelPath,
            tmpDir: Constants.tempDirectory,
            logDir: Constants.logDirectory
        )
    }

    /// Writes the plist to ~/Library/LaunchAgents/ then restarts the service.
    public func installLaunchdPlist(modelPath: URL, vadModelPath: URL?) async throws {
        let plistContent = generateLaunchdPlist(modelPath: modelPath, vadModelPath: vadModelPath)
        let plistURL = Constants.whisperServerPlistPath
        let launchAgentsDir = plistURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: launchAgentsDir,
            withIntermediateDirectories: true
        )

        try FileManager.default.createDirectory(
            at: Constants.tempDirectory,
            withIntermediateDirectories: true
        )

        guard let data = plistContent.data(using: .utf8) else {
            throw AppError.serverUnhealthy("failed to encode plist as UTF-8")
        }
        try data.write(to: plistURL, options: .atomic)
        AppLogger.shared.log(.info, "Plist written to \(plistURL.path)")

        let argv = ServerPlist.arguments(
            binaryPath: binaryPath,
            modelPath: modelPath,
            vadModelPath: vadModelPath,
            tmpDir: Constants.tempDirectory
        )
        AppLogger.shared.log(.info, "whisper-server argv: \(argv.joined(separator: " "))")

        // Restart if currently running
        let wasRunning = await launchdManager.isLoaded()
        if wasRunning {
            try await launchdManager.bootout()
        }
        try await launchdManager.bootstrap()
    }

}
