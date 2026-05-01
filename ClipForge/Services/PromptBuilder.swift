import Foundation

enum PromptBuilder {
    /// Compose the full prompt for the AI: system instructions + bundled references + transcript + user spec.
    static func buildPrompt(
        userSpec: String,
        transcript: Transcript,
        masterDuration: Double
    ) -> String {
        var sections: [String] = []

        // System instructions
        let systemMd = AppPaths.bundledPrompt("system.md") ?? defaultSystemPrompt
        sections.append("# System")
        sections.append(systemMd.trimmingCharacters(in: .whitespacesAndNewlines))

        // Bundled editorial guidelines (planning rules from References/guidelines/*.md)
        if let guidelinesFolder = AppPaths.bundledReferencesURL(in: "guidelines"),
           let guidelines = collectSamples(from: guidelinesFolder), !guidelines.isEmpty {
            sections.append("# Editorial guidelines")
            sections.append("Use these guidelines to PLAN your selection. They describe the editorial concept, the format, and what makes a strong short-form video for this series.")
            sections.append("```markdown")
            sections.append(guidelines)
            sections.append("```")
        }

        // Bundled reference scripts (style + format examples from References/samples/*.md)
        if let samplesFolder = AppPaths.bundledReferencesURL(in: "samples"),
           let samples = collectSamples(from: samplesFolder), !samples.isEmpty {
            sections.append("# Reference scripts (style + format examples)")
            sections.append("These are finished scripts in the desired format (annotated visuals + verbatim audio + FULL TRANSCRIPT). Use them to inform the structure, pacing, and tone of your output. Do NOT copy their content — only their shape and editorial sensibility.")
            sections.append("```markdown")
            sections.append(samples)
            sections.append("```")
        }

        // Master duration constraint
        sections.append("# Master Timeline")
        sections.append("The concatenated source has a total duration of \(String(format: "%.2f", masterDuration)) seconds. All clip timestamps you produce MUST satisfy 0 ≤ sourceStart < sourceEnd ≤ \(String(format: "%.2f", masterDuration)).")

        // Transcript
        sections.append("# Transcript (segment-level timestamps)")
        sections.append("Each line is `[start–end] text`. Timestamps are in `MM:SS.ss` (seconds within the master timeline).")
        sections.append("```")
        sections.append(transcript.asAnnotatedText())
        sections.append("```")

        // User spec
        sections.append("# User request")
        sections.append(userSpec.trimmingCharacters(in: .whitespacesAndNewlines))

        // Output contract
        sections.append("# Output")
        sections.append("Respond with ONE fenced ```json``` block and nothing else. Schema:")
        sections.append("""
        ```json
        {
          "scripts": [
            {
              "name": "instagram-10s",
              "theme": "founder lessons",
              "targetDurationSeconds": 10,
              "clips": [
                {"sourceStart": 12.34, "sourceEnd": 14.78, "verbatim": "exact words spoken in this clip"}
              ]
            }
          ]
        }
        ```
        """)

        return sections.joined(separator: "\n\n")
    }

    private static func collectSamples(from folder: URL) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        let allowed: Set<String> = ["md", "txt", "markdown"]
        let files = contents
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.isEmpty { return nil }

        var blocks: [String] = []
        for f in files {
            if let body = try? String(contentsOf: f, encoding: .utf8) {
                blocks.append("## \(f.lastPathComponent)\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }

    static let defaultSystemPrompt = """
    You are a video clip selector for a short-form auto-editor. Your job is to read an interview transcript with timestamps and select VERBATIM clips (contiguous runs of segments) that, when stitched in the order you specify, form the requested short-form videos.

    Rules:
    - Use ONLY words that appear in the transcript. Do NOT invent, paraphrase, or rewrite.
    - Each clip's sourceStart/sourceEnd must align with segment boundaries from the transcript.
    - Sum of clip durations per script should be close to (but not exceed by more than 20%) the requested target duration.
    - Each script must have a clear narrative arc consistent with its theme.
    - Output strict JSON, fenced in ```json … ```. No prose outside the fence.
    """
}
