import Foundation

// Parses the plain-text SRT body returned by whisper-server when
// response_format=srt is requested. Each SRT block is:
//
//   1
//   00:00:00,000 --> 00:00:04,120
//   Subtitle text, possibly
//   spanning multiple lines
//
// Blocks are separated by a blank line. Timestamps use HH:MM:SS,mmm with a
// comma before the milliseconds. Returns the blocks as TranscriptionSegments
// with start/end in seconds, mirroring what verbose_json would provide.
public enum SRTParser {

    public static func parse(_ srt: String) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []

        // Normalise CRLF and split into blocks on blank lines.
        let normalised = srt.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalised.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0) }
            guard let (start, end, textLineIndex) = locateTimestampLine(in: lines) else {
                continue
            }

            let textLines = lines[textLineIndex...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let text = textLines.joined(separator: " ")
            guard !text.isEmpty else { continue }

            segments.append(TranscriptionSegment(text: text, start: start, end: end))
        }

        return segments
    }

    /// Combined transcript text from all segments, newline-joined (each SRT
    /// block is one line of dictation), matching the shape callers expect from
    /// the JSON `text` field.
    public static func fullText(from segments: [TranscriptionSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // Finds the "HH:MM:SS,mmm --> HH:MM:SS,mmm" line within a block, returning
    // its parsed start/end and the index of the first text line after it. The
    // optional leading index line is skipped implicitly by scanning for the
    // arrow.
    private static func locateTimestampLine(in lines: [String]) -> (start: Double, end: Double, textLineIndex: Int)? {
        for (index, line) in lines.enumerated() {
            guard line.contains("-->") else { continue }
            let halves = line.components(separatedBy: "-->")
            guard halves.count == 2,
                  let start = parseTimestamp(halves[0]),
                  let end = parseTimestamp(halves[1]) else {
                return nil
            }
            return (start, end, index + 1)
        }
        return nil
    }

    /// Parses "HH:MM:SS,mmm" (whitespace-tolerant) into seconds.
    static func parseTimestamp(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Split seconds from milliseconds on the comma.
        let commaParts = trimmed.components(separatedBy: ",")
        guard commaParts.count == 2 else { return nil }

        let hms = commaParts[0].components(separatedBy: ":")
        guard hms.count == 3,
              let hours = Double(hms[0]),
              let minutes = Double(hms[1]),
              let seconds = Double(hms[2]),
              let millis = Double(commaParts[1]) else {
            return nil
        }

        return hours * 3600 + minutes * 60 + seconds + millis / 1000
    }
}
