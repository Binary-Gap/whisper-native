import SwiftUI
import WhisperNativeCore

// MARK: - Server Tab

struct ServerTab: View {
    @ObservedObject var store: SettingsStore
    @State private var serverStatus: ServerStatus = .checking

    private enum ServerStatus {
        case checking, running, stopped

        var label: String {
            switch self {
            case .checking: "Checking…"
            case .running: "Running"
            case .stopped: "Stopped"
            }
        }

        var color: Color {
            switch self {
            case .checking: .yellow
            case .running: .green
            case .stopped: .red
            }
        }
    }

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Status") {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Circle()
                                .fill(serverStatus.color)
                                .frame(width: 8, height: 8)
                                .shadow(color: serverStatus.color.opacity(0.6), radius: 3)
                            Text(serverStatus.label)
                                .font(DesignSystem.Typography.metadata)
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .animation(DesignSystem.Motion.smooth, value: serverStatus)

                        Button {
                            Task { await checkServerStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .symbolEffect(.rotate, isActive: serverStatus == .checking)
                        }
                        .buttonStyle(.borderless)
                        .help("Re-check server status")
                        .disabled(serverStatus == .checking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await checkServerStatus() }
    }

    private func checkServerStatus() async {
        serverStatus = .checking
        serverStatus = await store.checkServerAvailable() ? .running : .stopped
    }
}
