import Foundation

/// Renders Scripts into per-script output folders with stitched.mp4, clips/, and script.md.
final class Renderer {
    static let shared = Renderer()

    func render(
        scripts: [Script],
        master: URL,
        masterDuration: Double,
        projectRoot: URL,
        progress: @escaping (String) -> Void
    ) async throws -> [RenderResult] {
        var results: [RenderResult] = []
        for script in scripts {
            progress("Rendering script: \(script.name)")
            let result = try await renderOne(
                script: script,
                master: master,
                masterDuration: masterDuration,
                projectRoot: projectRoot,
                progress: progress
            )
            results.append(result)
        }
        return results
    }

    private func renderOne(
        script: Script,
        master: URL,
        masterDuration: Double,
        projectRoot: URL,
        progress: @escaping (String) -> Void
    ) async throws -> RenderResult {
        let safeName = sanitizeFilename(script.name)
        let outDir = projectRoot.appendingPathComponent(safeName, isDirectory: true)
        let clipsDir = outDir.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)

        // Trim each clip with frame-accurate cuts.
        var clipURLs: [URL] = []
        for (i, clip) in script.clips.enumerated() {
            let clamped = clampClip(clip, masterDuration: masterDuration)
            let out = clipsDir.appendingPathComponent(String(format: "%02d.mp4", i + 1))
            progress("  Trimming clip \(i+1)/\(script.clips.count) [\(formatTimecode(clamped.sourceStart))–\(formatTimecode(clamped.sourceEnd))]")
            try await FFmpegService.shared.trimClip(
                master: master,
                startSeconds: clamped.sourceStart,
                endSeconds: clamped.sourceEnd,
                output: out,
                progress: { _ in }
            )
            clipURLs.append(out)
        }

        // Stitch directly from master in a single ffmpeg pass via concat filter.
        // This bypasses PTS/audio-boundary glitches that arise from concatenating
        // independently-encoded clip files.
        let stitched = outDir.appendingPathComponent("stitched.mp4")
        progress("  Stitching \(script.clips.count) clip(s) from master → stitched.mp4 (single pass)")
        let clampedClips = script.clips.map { clampClip($0, masterDuration: masterDuration) }
        try await FFmpegService.shared.stitchFromMaster(
            master: master,
            clips: clampedClips,
            output: stitched,
            progress: { _ in }
        )

        // Write script.md
        let mdURL = outDir.appendingPathComponent("script.md")
        let md = renderMarkdown(script: script, master: master, clipFiles: clipURLs)
        try md.write(to: mdURL, atomically: true, encoding: .utf8)

        return RenderResult(
            scriptName: script.name,
            outputDir: outDir,
            scriptMarkdown: mdURL,
            stitched: stitched,
            clipFiles: clipURLs
        )
    }

    private func clampClip(_ clip: Clip, masterDuration: Double) -> Clip {
        let s = max(0, min(clip.sourceStart, masterDuration - 0.05))
        let e = max(s + 0.05, min(clip.sourceEnd, masterDuration))
        return Clip(
            sourceStart: s,
            sourceEnd: e,
            verbatim: clip.verbatim,
            visualSuggestion: clip.visualSuggestion,
            sectionHeader: clip.sectionHeader
        )
    }

    private func renderMarkdown(script: Script, master: URL, clipFiles: [URL]) -> String {
        var out = "# \(script.name) Rough Cut Script\n\n"
        out += "**Theme:** \(script.theme)  \n"
        let total = script.clips.reduce(0.0) { $0 + max(0, $1.sourceEnd - $1.sourceStart) }
        out += "**Target duration:** \(String(format: "%.1f", script.targetDurationSeconds))s · **Actual duration:** \(String(format: "%.2f", total))s  \n"
        out += "**Source:** `\(master.path)`\n\n"

        let hasAnyVisuals = script.clips.contains { ($0.visualSuggestion ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false }

        // Walk clips, breaking into sections whenever a clip carries a sectionHeader.
        // The first segment may have no header — render it as the lead-in.
        var sectionStartIndex = 0
        for (idx, clip) in script.clips.enumerated() {
            if idx > 0, let header = clip.sectionHeader, !header.trimmingCharacters(in: .whitespaces).isEmpty {
                // Emit previous section then start a new one.
                out += renderSection(
                    clips: Array(script.clips[sectionStartIndex..<idx]),
                    clipFiles: Array(clipFiles[sectionStartIndex..<min(idx, clipFiles.count)]),
                    sectionHeader: sectionStartIndex == 0
                        ? nil
                        : script.clips[sectionStartIndex].sectionHeader,
                    hasAnyVisuals: hasAnyVisuals
                )
                sectionStartIndex = idx
            }
        }
        // Final section
        let finalHeader: String? = {
            if script.clips.isEmpty { return nil }
            if sectionStartIndex == 0 {
                return script.clips[0].sectionHeader
            }
            return script.clips[sectionStartIndex].sectionHeader
        }()
        out += renderSection(
            clips: Array(script.clips[sectionStartIndex...]),
            clipFiles: Array(clipFiles[sectionStartIndex..<min(script.clips.count, clipFiles.count)]),
            sectionHeader: finalHeader,
            hasAnyVisuals: hasAnyVisuals
        )

        // FULL TRANSCRIPT block — verbatim per clip with master timecodes.
        out += "\n---\n\n"
        out += "## FULL TRANSCRIPT\n\n"
        for clip in script.clips {
            out += "[\(formatTimecode(clip.sourceStart)) – \(formatTimecode(clip.sourceEnd))]\n"
            out += clip.verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n\n"
        }
        return out
    }

    /// Render one section — optional `## header`, then either a two-column visuals|audio
    /// table (when at least one clip in the script has a visualSuggestion) or a single-column
    /// audio list.
    private func renderSection(
        clips: [Clip],
        clipFiles: [URL],
        sectionHeader: String?,
        hasAnyVisuals: Bool
    ) -> String {
        var out = ""
        if let header = sectionHeader, !header.trimmingCharacters(in: .whitespaces).isEmpty {
            out += "## \(header)\n\n"
        }
        if hasAnyVisuals {
            out += "| Visuals (Suggested) | Audio |\n"
            out += "|---|---|\n"
            for clip in clips {
                let visual = (clip.visualSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                let audio = clip.verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "| \(escapeTableCell(visual)) | \(escapeTableCell(audio)) |\n"
            }
            out += "\n"
        } else {
            for clip in clips {
                let audio = clip.verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "\(audio)\n\n"
            }
        }
        return out
    }

    /// Escape characters that would break a markdown table row.
    private func escapeTableCell(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "script" : trimmed
    }
}
