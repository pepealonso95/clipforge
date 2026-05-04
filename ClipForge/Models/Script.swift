import Foundation

/// One requested output video, made of ordered verbatim clips from the master timeline.
struct Script: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var theme: String
    var targetDurationSeconds: Double
    var clips: [Clip]

    private enum CodingKeys: String, CodingKey {
        case name, theme, targetDurationSeconds, clips
    }

    init(name: String, theme: String, targetDurationSeconds: Double, clips: [Clip]) {
        self.name = name
        self.theme = theme
        self.targetDurationSeconds = targetDurationSeconds
        self.clips = clips
    }

    var actualDuration: Double {
        clips.reduce(0.0) { $0 + $1.duration }
    }
}

/// A wrapper for the AI's response: an array of scripts.
struct ScriptResponse: Codable {
    let scripts: [Script]
}

/// One clip from the master timeline, identified by start/end timestamps in the master.
struct Clip: Codable, Identifiable {
    var id: UUID = UUID()
    /// Start time in master.mov (seconds).
    var sourceStart: Double
    /// End time in master.mov (seconds, exclusive).
    var sourceEnd: Double
    /// Verbatim text spoken in this clip (for the script.md and AI fidelity check).
    var verbatim: String
    /// Optional B-roll / shot suggestion the AI produces for the rough-cut script.
    /// Examples: "Shot: speaker on camera", "Stock: laptop with code", "Graphic: timeline diagram".
    var visualSuggestion: String?
    /// Optional sub-theme header. When present on a clip, the rough-cut renderer
    /// breaks the table and emits a `## <header>` heading before this clip.
    var sectionHeader: String?

    private enum CodingKeys: String, CodingKey {
        case sourceStart, sourceEnd, verbatim, visualSuggestion, sectionHeader
    }

    init(
        sourceStart: Double,
        sourceEnd: Double,
        verbatim: String,
        visualSuggestion: String? = nil,
        sectionHeader: String? = nil
    ) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.verbatim = verbatim
        self.visualSuggestion = visualSuggestion
        self.sectionHeader = sectionHeader
    }

    var duration: Double { max(0, sourceEnd - sourceStart) }
}
