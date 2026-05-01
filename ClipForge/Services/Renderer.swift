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
        return Clip(sourceStart: s, sourceEnd: e, verbatim: clip.verbatim)
    }

    private func renderMarkdown(script: Script, master: URL, clipFiles: [URL]) -> String {
        var out = "# \(script.name)\n\n"
        out += "**Theme:** \(script.theme)\n"
        out += "**Target duration:** \(String(format: "%.1f", script.targetDurationSeconds))s\n"
        let total = script.clips.reduce(0.0) { $0 + max(0, $1.sourceEnd - $1.sourceStart) }
        out += "**Actual duration:** \(String(format: "%.2f", total))s\n"
        out += "**Source:** `\(master.path)`\n\n"
        out += "## Clips\n\n"
        for (i, clip) in script.clips.enumerated() {
            let file = i < clipFiles.count ? clipFiles[i].lastPathComponent : "—"
            out += "### \(i + 1). [\(formatTimecode(clip.sourceStart))–\(formatTimecode(clip.sourceEnd))]  · `\(file)`\n\n"
            out += "> \(clip.verbatim.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        return out
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "script" : trimmed
    }
}
