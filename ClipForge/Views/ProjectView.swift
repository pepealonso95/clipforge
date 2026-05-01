import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProjectView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pipeline = Pipeline()

    @State private var sourceFiles: [URL] = []
    @State private var projectName: String = ""
    @State private var userPrompt: String = ""

    /// Base directory under which each project's folder is created.
    /// `~/Movies/ClipForge/<projectName>/`
    private var projectsBase: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let base = movies.appendingPathComponent("ClipForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Auto-generated name from the first source video + a slug of the prompt.
    /// Used when the user leaves the project name field empty.
    private var autoProjectName: String {
        let sourceSlug = sourceFiles.first.map {
            slugify($0.deletingPathExtension().lastPathComponent, maxLength: 24)
        } ?? ""
        let promptSlug = slugify(userPrompt, maxLength: 32)
        switch (sourceSlug.isEmpty, promptSlug.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return sourceSlug
        case (true, false):  return promptSlug
        case (false, false): return "\(sourceSlug)-\(promptSlug)"
        }
    }

    /// What we actually use: the user's typed name if any, else the auto-generated one,
    /// else the literal "untitled-project" as a final fallback.
    private var effectiveProjectName: String {
        let typed = projectName.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let auto = autoProjectName
        return auto.isEmpty ? "untitled-project" : auto
    }

    private var resolvedOutputDir: URL {
        projectsBase.appendingPathComponent(effectiveProjectName, isDirectory: true)
    }

    /// Lowercase, replace non-alphanumeric with `-`, collapse runs, trim, cap length.
    private func slugify(_ s: String, maxLength: Int) -> String {
        let lower = s.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if !out.isEmpty && out.last != "-" {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if trimmed.count <= maxLength { return trimmed }
        // Truncate at a `-` boundary if possible.
        let cut = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        let prefix = String(trimmed[..<cut])
        if let lastDash = prefix.lastIndex(of: "-"), prefix.distance(from: prefix.startIndex, to: lastDash) > maxLength / 2 {
            return String(prefix[..<lastDash])
        }
        return prefix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    var body: some View {
        Group {
            if pipeline.artifacts != nil {
                EditorView(
                    artifacts: Binding(
                        get: { pipeline.artifacts ?? placeholderArtifacts() },
                        set: { pipeline.artifacts = $0 }
                    ),
                    onBackToSetup: {
                        pipeline.artifacts = nil
                        pipeline.results = []
                    }
                )
            } else {
                setupBody
            }
        }
    }

    private func placeholderArtifacts() -> PipelineArtifacts {
        // Should never be reached because the parent guards on artifacts != nil,
        // but Binding<T> needs a non-optional accessor.
        let dummy = ProjectPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        return PipelineArtifacts(
            projectRoot: dummy.projectRoot,
            masterURL: dummy.masterMov,
            masterDuration: 0,
            transcript: Transcript(language: nil, duration: 0, segments: [], words: nil),
            scripts: [],
            segments: [],
            renderResults: [],
            paths: dummy
        )
    }

    private var setupBody: some View {
        HSplitView {
            // Left: inputs
            VStack(alignment: .leading, spacing: 16) {
                Text("ClipForge").font(.largeTitle).bold()
                Text("AI auto-editor for raw interview footage")
                    .foregroundStyle(.secondary)

                Divider()

                projectField
                sourcesField
                outputInfo
                promptField

                HStack {
                    Button(pipeline.isRunning ? "Cancel" : "Generate") {
                        if pipeline.isRunning {
                            pipeline.cancel()
                        } else {
                            runPipeline()
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canRun && !pipeline.isRunning)
                    .buttonStyle(.borderedProminent)

                    if pipeline.isRunning, let stage = pipeline.currentStage {
                        ProgressView().controlSize(.small)
                        Text(stage.rawValue).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 380, idealWidth: 420)

            // Right: log + results
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pipeline").font(.headline)
                    Spacer()
                    if let err = pipeline.error {
                        Text(err.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(pipeline.log.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.contains("ERROR") ? .red : .primary)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: pipeline.log.count) { _, _ in
                        if let last = pipeline.log.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }

                if !pipeline.results.isEmpty {
                    Divider()
                    Text("Outputs").font(.headline)
                    ForEach(pipeline.results, id: \.scriptName) { r in
                        HStack {
                            Text(r.scriptName).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([r.outputDir])
                            }
                            Button("Play stitched") {
                                NSWorkspace.shared.open(r.stitched)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 420)
        }
    }

    // MARK: - Subviews

    private var projectField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Project name").font(.callout).foregroundStyle(.secondary)
                Text("(optional)").font(.caption).foregroundStyle(.tertiary)
            }
            TextField(autoProjectName.isEmpty ? "untitled-project" : autoProjectName, text: $projectName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var sourcesField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Source videos").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Add…") { pickSources() }
                if !sourceFiles.isEmpty {
                    Button("Clear") { sourceFiles = [] }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if sourceFiles.isEmpty {
                    Text("Drop videos here or click Add…")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(Array(sourceFiles.enumerated()), id: \.offset) { _, url in
                        Text(url.lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
                return true
            }
        }
    }

    private var outputInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Output").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([projectsBase])
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reveal the ClipForge projects folder in Finder")
            }
            Text(resolvedOutputDir.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $userPrompt)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    // MARK: - Actions

    private var canRun: Bool {
        !sourceFiles.isEmpty
            && !effectiveProjectName.isEmpty
            && !userPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runPipeline() {
        let inputs = ProjectInputs(
            sourceFiles: sourceFiles,
            outputDirectory: projectsBase,
            projectName: effectiveProjectName,
            userPrompt: userPrompt
        )
        pipeline.run(inputs: inputs, settings: settings)
    }

    private func pickSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        if panel.runModal() == .OK {
            sourceFiles.append(contentsOf: panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    sourceFiles.append(url)
                }
            }
        }
    }
}
