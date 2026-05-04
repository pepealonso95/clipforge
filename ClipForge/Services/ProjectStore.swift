import Foundation

/// Lightweight metadata about a project on disk, shown in the home list.
struct ProjectSummary: Identifiable, Hashable {
    var id: URL { path }
    let name: String
    let path: URL
    let lastModified: Date
    let scriptsCount: Int?
    /// True when master.mov + transcript.json + scripts.json all exist on disk.
    let isComplete: Bool
}

/// Reads the on-disk projects directory (`~/Movies/ClipForge/`) and rehydrates
/// `PipelineArtifacts` from previously-completed runs so the user can re-open
/// a project without re-running the pipeline.
enum ProjectStore {
    static var projectsBase: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let base = movies.appendingPathComponent("ClipForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func listProjects() -> [ProjectSummary] {
        let fm = FileManager.default
        let base = projectsBase
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> ProjectSummary? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let paths = ProjectPaths(root: url)
            let isComplete = fm.fileExists(atPath: paths.masterMov.path)
                && fm.fileExists(atPath: paths.transcriptJSON.path)
                && fm.fileExists(atPath: paths.scriptsJSON.path)

            // Skip directories that don't even have a master.mov — they're either
            // half-cancelled runs or accidentally-created folders.
            guard fm.fileExists(atPath: paths.masterMov.path) else { return nil }

            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast

            var scriptsCount: Int? = nil
            if let data = try? Data(contentsOf: paths.scriptsJSON),
               let resp = try? JSONDecoder().decode(ScriptResponse.self, from: data) {
                scriptsCount = resp.scripts.count
            }

            return ProjectSummary(
                name: url.lastPathComponent,
                path: url,
                lastModified: modDate,
                scriptsCount: scriptsCount,
                isComplete: isComplete
            )
        }
        .sorted { $0.lastModified > $1.lastModified }
    }

    /// Best-effort rehydration of artifacts. Returns nil when required JSON is
    /// missing or undecodable — caller should fall back to setup.
    static func loadArtifacts(at projectRoot: URL) -> PipelineArtifacts? {
        let paths = ProjectPaths(root: projectRoot)
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.masterMov.path) else { return nil }

        guard let transcriptData = try? Data(contentsOf: paths.transcriptJSON),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: transcriptData)
        else { return nil }

        guard let scriptsData = try? Data(contentsOf: paths.scriptsJSON),
              let resp = try? JSONDecoder().decode(ScriptResponse.self, from: scriptsData)
        else { return nil }

        var segments: [SourceSegment] = []
        if let data = try? Data(contentsOf: paths.segmentsJSON),
           let decoded = try? JSONDecoder().decode([SourceSegment].self, from: data) {
            segments = decoded
        }

        let masterDuration = transcript.duration
            ?? segments.reduce(0.0) { $0 + $1.duration }

        var renderResults: [RenderResult] = []
        for s in resp.scripts {
            let safe = sanitizedScriptName(s.name)
            let outDir = projectRoot.appendingPathComponent(safe, isDirectory: true)
            let stitched = outDir.appendingPathComponent("stitched.mp4")
            let scriptMd = outDir.appendingPathComponent("script.md")
            guard fm.fileExists(atPath: stitched.path) else { continue }
            let clipFiles = (try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
            renderResults.append(RenderResult(
                scriptName: s.name,
                outputDir: outDir,
                scriptMarkdown: scriptMd,
                stitched: stitched,
                clipFiles: clipFiles
            ))
        }

        return PipelineArtifacts(
            projectRoot: projectRoot,
            masterURL: paths.masterMov,
            masterDuration: masterDuration,
            transcript: transcript,
            scripts: resp.scripts,
            segments: segments,
            renderResults: renderResults,
            paths: paths
        )
    }

    // MARK: - Last opened

    private static let lastOpenedKey = "lastOpenedProjectPath"

    static var lastOpenedProjectPath: URL? {
        get {
            guard let s = UserDefaults.standard.string(forKey: lastOpenedKey) else { return nil }
            let url = URL(fileURLWithPath: s)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: lastOpenedKey)
        }
    }

    // MARK: - Helpers

    /// Mirrors `Renderer.sanitizeFilename` so we can find per-script output
    /// directories created by the renderer.
    private static func sanitizedScriptName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "script" : trimmed
    }
}
