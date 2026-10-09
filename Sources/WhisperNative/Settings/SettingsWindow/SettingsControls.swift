import AppKit
import SwiftUI
import WhisperNativeCore

// MARK: - Reusable controls

/// A toggle whose explanation sits behind a "?" button next to its title.
struct LabeledToggle: View {
    let title: String
    let help: String
    /// When set, the toggle is disabled (its value is kept) and this reason
    /// shows under it.
    let unavailableReason: String?
    @Binding var isOn: Bool

    init(_ title: String, help: String, unavailableReason: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.help = help
        self.unavailableReason = unavailableReason
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Toggle(isOn: $isOn) {
                InfoLabel(title, info: help)
                    .font(DesignSystem.Typography.rowTitle)
            }
            .disabled(unavailableReason != nil)
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A single-value text field (path or prompt) that wraps and grows to fit its
/// content instead of scrolling. `TextField(axis: .vertical)` reports its
/// wrapped intrinsic height through the normal layout pass, so every line stays
/// visible without clipping — including after the view is rebuilt on a
/// settings-tab switch.
struct GrowingTextField: View {
    let placeholder: String
    @Binding var text: String
    let font: Font

    init(_ placeholder: String = "", text: Binding<String>, font: Font) {
        self.placeholder = placeholder
        self._text = text
        self.font = font
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .lineLimit(1...)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared "text box" chrome used by every multi-line text surface in Settings
/// (models directory, VAD path, initial prompt, read-aloud sentence): rounded
/// field background + separator border, content flush-left and multi-line.
/// `contentPadding` lets a caller give the text a little more breathing room
/// from the border (the read-aloud sentence wants a roomier inset).
struct SettingsTextBox<Content: View>: View {
    var contentPadding: CGFloat
    /// Optional minimum height for the text area. Applied to the box (not the
    /// inner field) with top alignment so the text stays flush at the top edge
    /// instead of vertically centering in the enlarged frame.
    var minContentHeight: CGFloat?
    @ViewBuilder var content: Content

    init(contentPadding: CGFloat = 6, minContentHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.contentPadding = contentPadding
        self.minContentHeight = minContentHeight
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: minContentHeight, alignment: .topLeading)
            .multilineTextAlignment(.leading)
            .padding(contentPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            )
    }
}

/// A filesystem path control that commits on submit/blur (not per keystroke),
/// shows the meaningful tail of long paths, and signals on-disk existence.
struct PathField: View {
    let label: String
    let help: String
    @Binding var path: URLBox
    let isDirectory: Bool
    let checksExistence: Bool
    let optional: Bool
    /// When true, the path is shown as a non-editable truncated label (only the
    /// Choose… panel changes it). Avoids the multi-line text editor's focus-steal
    /// and alignment quirks for fields that don't benefit from typing.
    let readOnly: Bool

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    /// Initializer for a required URL binding.
    init(
        label: String,
        help: String,
        path: Binding<URL>,
        isDirectory: Bool,
        checksExistence: Bool,
        readOnly: Bool = false
    ) {
        self.label = label
        self.help = help
        self._path = URLBox.binding(required: path)
        self.isDirectory = isDirectory
        self.checksExistence = checksExistence
        self.optional = false
        self.readOnly = readOnly
    }

    /// Initializer for an optional URL binding.
    init(
        label: String,
        help: String,
        path: Binding<URL?>,
        isDirectory: Bool,
        checksExistence: Bool,
        optional: Bool,
        readOnly: Bool = false
    ) {
        self.label = label
        self.help = help
        self._path = URLBox.binding(optional: path)
        self.isDirectory = isDirectory
        self.checksExistence = checksExistence
        self.optional = optional
        self.readOnly = readOnly
    }

    private var exists: Bool {
        guard let url = path.url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                InfoLabel(label, info: help)
                if checksExistence, path.url != nil {
                    Circle()
                        .fill(exists ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .help(exists ? "Found on disk" : "Not found on disk")
                }
            }

            HStack(alignment: .top, spacing: 8) {
                if readOnly {
                    // Wraps onto multiple lines when the path is too long for one;
                    // full path stays readable rather than head-truncated.
                    SettingsTextBox {
                        Text(path.url?.path(percentEncoded: false) ?? "—")
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                } else {
                    // GrowingTextField wraps and left-aligns multi-line text natively, so the
                    // full path stays visible flush-left (the bordered TextField centers it).
                    SettingsTextBox {
                        GrowingTextField(text: $draft, font: .system(.callout, design: .monospaced))
                    }
                    // Accent the border while focused, on top of the shared chrome.
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .opacity(isFocused ? 1 : 0)
                    )
                    .focused($isFocused)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                }

                if optional, path.url != nil {
                    Button {
                        path.url = nil
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear")
                }

                Button("Choose…") { choose() }
            }
        }
        .onAppear { draft = path.url?.path(percentEncoded: false) ?? "" }
        .onChange(of: path.url) { _, newURL in
            // Keep the draft in sync when the path is changed elsewhere (e.g. the panel).
            if !isFocused {
                draft = newURL?.path(percentEncoded: false) ?? ""
            }
        }
    }

    private func commit() {
        // Collapse any stray newlines (the vertical field accepts Enter) into a clean path.
        let trimmed = draft
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if optional {
                path.url = nil
            } else {
                // Reject empty for required fields; restore the prior value.
                draft = path.url?.path(percentEncoded: false) ?? ""
            }
            return
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        path.url = URL(fileURLWithPath: expanded)
        draft = expanded
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !isDirectory
        panel.canChooseDirectories = isDirectory
        panel.allowsMultipleSelection = false
        panel.directoryURL = path.url
        if panel.runModal() == .OK, let url = panel.url {
            path.url = url
            draft = url.path(percentEncoded: false)
        }
    }
}

/// Type-erases required vs optional URL bindings so `PathField` has one storage shape.
struct URLBox: Equatable {
    var url: URL?

    static func binding(required: Binding<URL>) -> Binding<URLBox> {
        Binding(
            get: { URLBox(url: required.wrappedValue) },
            set: { box in
                if let url = box.url { required.wrappedValue = url }
            }
        )
    }

    static func binding(optional: Binding<URL?>) -> Binding<URLBox> {
        Binding(
            get: { URLBox(url: optional.wrappedValue) },
            set: { optional.wrappedValue = $0.url }
        )
    }
}
