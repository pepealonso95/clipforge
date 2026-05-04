import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVKit

/// Idle setup screen: gathers inputs, hands a built `ProjectInputs` up to the
/// parent via `onGenerate`. Owns all per-form state so the parent can stay a
/// thin state router.
struct SetupView: View {
    var onGenerate: (ProjectInputs) -> Void
    var onBack: () -> Void

    @State private var sourceFiles: [URL] = []
    @State private var projectName: String = ""
    @State private var userPrompt: String = ""
    @State private var previewIndex: Int = 0
    @State private var previewPlayer: AVPlayer? = nil

    private var projectsBase: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let base = movies.appendingPathComponent("ClipForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

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

    private var effectiveProjectName: String {
        let typed = projectName.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let auto = autoProjectName
        return auto.isEmpty ? "untitled-project" : auto
    }

    private var resolvedOutputDir: URL {
        projectsBase.appendingPathComponent(effectiveProjectName, isDirectory: true)
    }

    private var canRun: Bool {
        !sourceFiles.isEmpty
            && !effectiveProjectName.isEmpty
            && !userPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                projectField
                sourcesField
                outputInfo
                promptField
                generateButton
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onBack) {
                Label("Projects", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                Text("New project").font(.largeTitle).bold()
                Text("Pick your sources and tell ClipForge what to make.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    private var projectField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Project name").font(.callout).foregroundStyle(.secondary)
                Text("(optional)").font(.caption).foregroundStyle(.tertiary)
            }
            TextField(autoProjectName.isEmpty ? "untitled-project" : autoProjectName, text: $projectName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var sourcesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Source videos").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Add…") { pickSources() }
                if !sourceFiles.isEmpty {
                    Button("Clear") {
                        sourceFiles = []
                        previewIndex = 0
                        refreshPreviewPlayer()
                    }
                }
            }
            sourceList
            if let player = previewPlayer, sourceFiles.indices.contains(previewIndex) {
                AVPlayerViewRepresentable(player: player)
                    .frame(height: 220)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sourceFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Drop videos here or click Add…")
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ForEach(Array(sourceFiles.enumerated()), id: \.offset) { idx, url in
                    Button(action: { previewIndex = idx; refreshPreviewPlayer() }) {
                        HStack(spacing: 6) {
                            Image(systemName: idx == previewIndex ? "play.circle.fill" : "circle")
                                .foregroundStyle(idx == previewIndex ? Color.accentColor : Color.secondary.opacity(0.5))
                            Text(url.lastPathComponent)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: sourceFiles.isEmpty ? 1 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var outputInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $userPrompt)
                .font(.body)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private var generateButton: some View {
        HStack {
            Spacer()
            Button("Generate clips") { submit() }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canRun)
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func submit() {
        let inputs = ProjectInputs(
            sourceFiles: sourceFiles,
            outputDirectory: projectsBase,
            projectName: effectiveProjectName,
            userPrompt: userPrompt
        )
        onGenerate(inputs)
    }

    private func pickSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        if panel.runModal() == .OK {
            let wasEmpty = sourceFiles.isEmpty
            sourceFiles.append(contentsOf: panel.urls)
            if wasEmpty {
                previewIndex = 0
                refreshPreviewPlayer()
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let wasEmpty = sourceFiles.isEmpty
                    sourceFiles.append(url)
                    if wasEmpty {
                        previewIndex = 0
                        refreshPreviewPlayer()
                    }
                }
            }
        }
    }

    private func refreshPreviewPlayer() {
        guard sourceFiles.indices.contains(previewIndex) else {
            previewPlayer?.pause()
            previewPlayer = nil
            return
        }
        let url = sourceFiles[previewIndex]
        if let p = previewPlayer {
            p.pause()
            p.replaceCurrentItem(with: AVPlayerItem(url: url))
        } else {
            previewPlayer = AVPlayer(url: url)
        }
    }

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
        let cut = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        let prefix = String(trimmed[..<cut])
        if let lastDash = prefix.lastIndex(of: "-"), prefix.distance(from: prefix.startIndex, to: lastDash) > maxLength / 2 {
            return String(prefix[..<lastDash])
        }
        return prefix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
