import Foundation

/// Greedy word wrap for backends without server-side wrapping (Parakeet), matching
/// whisper-server's max_len + split_on_word: lines break between words at or
/// below `width` characters. Existing line breaks are kept; a single word longer
/// than `width` stays whole on its own line.
public enum LineWrapper {

    public static func wrap(_ text: String, width: Int) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { wrapLine(String($0), width: width) }
            .joined(separator: "\n")
    }

    private static func wrapLine(_ line: String, width: Int) -> String {
        var lines: [String] = []
        var current = ""
        for word in line.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        lines.append(current)
        return lines.joined(separator: "\n")
    }
}
