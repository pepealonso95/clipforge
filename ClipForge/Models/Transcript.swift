import Foundation

/// Normalized transcript shape. Both whisper.cpp and OpenAI API are mapped to this.
struct Transcript: Codable {
    var language: String?
    var duration: Double?
    var segments: [TranscriptSegment]
    var words: [TranscriptWord]?
}

struct TranscriptSegment: Codable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
}

struct TranscriptWord: Codable {
    let word: String
    let start: Double
    let end: Double
}

extension Transcript {
    /// Render a compact, AI-friendly view: each segment as one line with [start–end] text.
    func asAnnotatedText() -> String {
        var lines: [String] = []
        for s in segments {
            let line = "[\(formatTimecode(s.start))–\(formatTimecode(s.end))] \(s.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

func formatTimecode(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let mm = Int(total) / 60
    let ss = total - Double(Int(total) / 60 * 60)
    return String(format: "%02d:%05.2f", mm, ss)
}
