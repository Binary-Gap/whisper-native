import Foundation

// MARK: - Server status display

/// Last known result of the whisper daemon's health check.
public enum WhisperServerHealth: Equatable, Sendable {
    case checking
    case running
    case stopped
}

/// How a status line is colored: `neutral` for a normal idle state (engine not
/// in use), `problem` only for something that should work and doesn't.
public enum StatusTone: Equatable, Sendable {
    case neutral
    case good
    case pending
    case problem
}

/// Start or stop request in flight from the Whisper page.
public enum WhisperServerToggle: Equatable, Sendable {
    case starting
    case stopping
}

/// What the Whisper page's server row shows, and why Start/Stop Server is
/// disabled.
public struct WhisperServerDisplay: Equatable, Sendable {
    public let label: String
    public let tone: StatusTone

    public init(label: String, tone: StatusTone) {
        self.label = label
        self.tone = tone
    }

    /// A stopped daemon is a problem only while Whisper is the active engine;
    /// otherwise it's the expected state and reads as neutral.
    public static func resolve(
        health: WhisperServerHealth,
        isWhisperActive: Bool,
        toggle: WhisperServerToggle? = nil
    ) -> WhisperServerDisplay {
        switch toggle {
        case .starting: return WhisperServerDisplay(label: "Starting…", tone: .pending)
        case .stopping: return WhisperServerDisplay(label: "Stopping…", tone: .pending)
        case nil: break
        }
        switch health {
        case .checking:
            return WhisperServerDisplay(label: "Checking…", tone: .pending)
        case .running:
            return WhisperServerDisplay(label: "Running", tone: .good)
        case .stopped:
            return isWhisperActive
                ? WhisperServerDisplay(label: "Stopped", tone: .problem)
                : WhisperServerDisplay(label: "Not running, Whisper isn't the active engine", tone: .neutral)
        }
    }

    /// Why Start/Stop Server is disabled (shown as its tooltip); nil when it
    /// can be used.
    public static func toggleBlockedReason(
        isWhisperActive: Bool,
        isDownloading: Bool,
        health: WhisperServerHealth,
        isToggling: Bool
    ) -> String? {
        if !isWhisperActive { return "Use Whisper first: the server runs only while Whisper is the active engine." }
        if isDownloading { return "Wait for the model download to finish." }
        if isToggling { return "Wait for the server to finish starting or stopping." }
        if health == .checking { return "Checking the server status…" }
        return nil
    }
}

// MARK: - Model preparation

/// What has to happen before the whisper daemon can start, given which of
/// its files are on disk (after the selection was pointed at a downloaded
/// model when the selected one is missing).
public enum WhisperModelPreparation: Equatable, Sendable {
    /// Model and VAD model are readable: start the daemon.
    case ready
    /// Only the ~1 MB VAD model is missing: fetched without asking.
    case downloadVadOnly
    /// No whisper model on disk: ask before downloading the recommended one.
    case askToDownloadModel

    public static func plan(modelReadable: Bool, vadReadable: Bool) -> WhisperModelPreparation {
        guard modelReadable else { return .askToDownloadModel }
        return vadReadable ? .ready : .downloadVadOnly
    }
}
