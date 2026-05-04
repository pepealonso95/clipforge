import SwiftUI
import AVKit
import AppKit

private enum PreviewMode: Hashable {
    case source
    case finalCut
}

/// Editor mode shown after a successful pipeline run.
///
/// Layout (full window):
///   ┌── toolbar ──────────────────────────────────────────────┐
///   ├── script tabs ──────────────────────────────────────────┤
///   ├── player + transcript (left) │ clips + re-render (right)┤
///   └─────────────────────────────────────────────────────────┘
struct EditorView: View {
    @Binding var artifacts: PipelineArtifacts
    let onBack: () -> Void

    @StateObject private var playerCtrl: PlayerController
    @State private var selectedScriptIndex: Int = 0
    @State private var isRendering: Bool = false
    @State private var renderError: String? = nil
    @State private var lastRenderedAt: Date? = nil
    @State private var previewMode: PreviewMode
    /// Signature of each script's clips at the moment it was last successfully
    /// rendered. Used to decide whether "Save & Re-render" should be enabled.
    @State private var renderedSignatures: [UUID: String] = [:]

    init(artifacts: Binding<PipelineArtifacts>, onBack: @escaping () -> Void) {
        self._artifacts = artifacts
        self.onBack = onBack

        // Prefer playing the final cut when one already exists for the first
        // script — that's the user's most likely starting view.
        let a = artifacts.wrappedValue
        let initial = Self.initialPreview(for: a)
        self._playerCtrl = StateObject(wrappedValue: PlayerController(url: initial.url))
        self._previewMode = State(initialValue: initial.mode)
    }

    private static func initialPreview(for a: PipelineArtifacts) -> (url: URL, mode: PreviewMode) {
        if let s = a.scripts.first {
            let safe = Self.staticSanitize(s.name)
            let stitched = a.projectRoot
                .appendingPathComponent(safe, isDirectory: true)
                .appendingPathComponent("stitched.mp4")
            if FileManager.default.fileExists(atPath: stitched.path) {
                return (stitched, .finalCut)
            }
        }
        return (a.masterURL, .source)
    }

    private static func staticSanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "script" : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            scriptTabs
            Divider()
            HSplitView {
                leftPane
                    .frame(minWidth: 480, idealWidth: 600)
                rightPane
                    .frame(minWidth: 320, idealWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            attachTimeObserver()
            initializeSignatures()
        }
        .onChange(of: selectedScriptIndex) { _, _ in
            // Stitched files are per-script; reset preview when switching.
            switchScriptPreview()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Projects", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 18)
            Text(artifacts.projectRoot.lastPathComponent)
                .font(.headline)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(String(format: "%.1f", artifacts.masterDuration))s master")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let lastRenderedAt {
                Text("Re-rendered \(timeAgo(lastRenderedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([artifacts.projectRoot])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Script tabs

    private var scriptTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(artifacts.scripts.enumerated()), id: \.offset) { idx, s in
                    ScriptTab(
                        name: s.name,
                        clipCount: s.clips.count,
                        isActive: idx == selectedScriptIndex,
                        action: { selectedScriptIndex = idx }
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            playerHeader
            playerSurface
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            scrubBar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()
            TranscriptView(
                transcript: artifacts.transcript,
                currentTime: masterTimeForTranscript,
                activeScript: currentScript,
                onSeek: { t in
                    ensureSourceMode()
                    playerCtrl.seek(to: t)
                    playerCtrl.play()
                },
                onToggle: { segment in
                    guard artifacts.scripts.indices.contains(selectedScriptIndex) else { return }
                    artifacts.scripts[selectedScriptIndex]
                        .toggleSegment(segment, transcript: artifacts.transcript)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playerHeader: some View {
        HStack(alignment: .center) {
            PreviewModeSegmented(
                mode: previewMode,
                hasStitched: hasStitched,
                onSelect: { setPreviewMode($0) }
            )
            Spacer()
            if previewMode == .finalCut {
                Label("Showing rendered output", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
            } else if hasStitched {
                Text("Final cut available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Re-render to enable Final cut")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var playerSurface: some View {
        AVPlayerViewRepresentable(player: playerCtrl.player)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 280, idealHeight: 360, maxHeight: 460)
    }

    private var scrubBar: some View {
        HStack(spacing: 12) {
            Text(formatTimecode(playerCtrl.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { min(playerCtrl.currentTime, activeDuration) },
                    set: { newValue in
                        playerCtrl.currentTime = newValue
                        playerCtrl.seek(to: newValue)
                    }
                ),
                in: 0...max(activeDuration, 0.01)
            )
            Text(formatTimecode(activeDuration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Right pane

    private var rightPane: some View {
        ScriptEditorPane(
            scripts: $artifacts.scripts,
            selectedIndex: selectedScriptIndex,
            isDirty: currentScriptNeedsRender,
            onPlayClip: { clip in
                ensureSourceMode()
                playerCtrl.playClip(start: clip.sourceStart, end: clip.sourceEnd)
            },
            onRerender: rerenderCurrent,
            isRendering: isRendering,
            renderError: renderError
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived state

    private var currentScript: Script? {
        artifacts.scripts.indices.contains(selectedScriptIndex)
            ? artifacts.scripts[selectedScriptIndex] : nil
    }

    private func stitchedURLForCurrent() -> URL? {
        guard let s = currentScript else { return nil }
        let safe = sanitizeFilename(s.name)
        return artifacts.projectRoot
            .appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("stitched.mp4")
    }

    private var hasStitched: Bool {
        guard let url = stitchedURLForCurrent() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Duration of whatever is currently loaded in the player.
    /// In Source mode that's the master timeline; in Final cut mode it's the
    /// sum of the active script's clip durations (the stitched.mp4 length).
    private var activeDuration: Double {
        switch previewMode {
        case .source:   return artifacts.masterDuration
        case .finalCut: return stitchedDurationForCurrent
        }
    }

    private var stitchedDurationForCurrent: Double {
        currentScript?.clips.reduce(0.0) { $0 + $1.duration } ?? 0
    }

    /// Current playback time mapped into the master (transcript) timeline.
    /// In Source mode this is just the player's time. In Final cut mode it
    /// walks the active script's clips to translate stitched-time into the
    /// corresponding moment in the source video.
    private var masterTimeForTranscript: Double {
        switch previewMode {
        case .source:
            return playerCtrl.currentTime
        case .finalCut:
            guard let clips = currentScript?.clips, !clips.isEmpty else {
                return -1
            }
            let t = max(0, playerCtrl.currentTime)
            var cumulative = 0.0
            for clip in clips {
                let dur = clip.duration
                if t < cumulative + dur || clip.id == clips.last?.id {
                    return clip.sourceStart + (t - cumulative)
                }
                cumulative += dur
            }
            return clips.last.map { $0.sourceEnd } ?? 0
        }
    }

    /// True when the active script has changes that haven't been rendered yet
    /// (or has never been rendered). Drives the Save & Re-render disabled state.
    private var currentScriptNeedsRender: Bool {
        guard let s = currentScript, !s.clips.isEmpty else { return false }
        guard let saved = renderedSignatures[s.id] else { return true }
        return saved != Self.signature(of: s)
    }

    private static func signature(of s: Script) -> String {
        s.clips
            .map { String(format: "%.4f-%.4f", $0.sourceStart, $0.sourceEnd) }
            .joined(separator: "|")
    }

    /// Snapshot the signatures of any scripts that already have a stitched
    /// render on disk — those count as "clean" until the user edits them.
    private func initializeSignatures() {
        for s in artifacts.scripts {
            let safe = sanitizeFilename(s.name)
            let stitched = artifacts.projectRoot
                .appendingPathComponent(safe, isDirectory: true)
                .appendingPathComponent("stitched.mp4")
            if FileManager.default.fileExists(atPath: stitched.path) {
                renderedSignatures[s.id] = Self.signature(of: s)
            }
        }
    }

    // MARK: - Actions

    private func setPreviewMode(_ mode: PreviewMode) {
        switch mode {
        case .source:
            ensureSourceMode()
        case .finalCut:
            guard let url = stitchedURLForCurrent(),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            previewMode = .finalCut
            playerCtrl.replace(url: url)
            playerCtrl.play()
        }
    }

    private func ensureSourceMode() {
        guard previewMode != .source else { return }
        previewMode = .source
        playerCtrl.replace(url: artifacts.masterURL)
    }

    /// When the active script changes, the per-script stitched.mp4 changes too.
    /// If we were watching final cut, swap to the new one (or fall back to source).
    private func switchScriptPreview() {
        guard previewMode == .finalCut else { return }
        if let url = stitchedURLForCurrent(), FileManager.default.fileExists(atPath: url.path) {
            playerCtrl.replace(url: url)
        } else {
            ensureSourceMode()
        }
    }

    private func rerenderCurrent() {
        guard let script = currentScript else { return }
        isRendering = true
        renderError = nil

        let scriptCopy = script
        let master = artifacts.masterURL
        let duration = artifacts.masterDuration
        let projectRoot = artifacts.projectRoot

        Task {
            do {
                let results = try await Renderer.shared.render(
                    scripts: [scriptCopy],
                    master: master,
                    masterDuration: duration,
                    projectRoot: projectRoot,
                    progress: { _ in }
                )
                await MainActor.run {
                    if let r = results.first,
                       let idx = artifacts.renderResults.firstIndex(where: { $0.scriptName == r.scriptName }) {
                        artifacts.renderResults[idx] = r
                    } else if let r = results.first {
                        artifacts.renderResults.append(r)
                    }
                    isRendering = false
                    lastRenderedAt = Date()
                    renderedSignatures[scriptCopy.id] = Self.signature(of: scriptCopy)
                }
            } catch {
                await MainActor.run {
                    renderError = error.localizedDescription
                    isRendering = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func attachTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        playerCtrl.player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if time.seconds.isFinite {
                playerCtrl.currentTime = time.seconds
            }
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "script" : trimmed
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }
}

// MARK: - Custom controls

/// Browser-style tab for switching the active script.
private struct ScriptTab: View {
    let name: String
    let clipCount: Int
    let isActive: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.callout)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                Text("\(clipCount)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isActive
                                ? Color.accentColor.opacity(0.15)
                                : Color.secondary.opacity(0.12)
                        )
                    )
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        if isActive { return Color.accentColor.opacity(0.12) }
        if hovered { return Color.secondary.opacity(0.10) }
        return Color.clear
    }
}

/// Custom segmented control for switching between Source and Final cut.
/// SwiftUI's `Picker(.segmented)` doesn't let us disable individual tags or
/// style them per-state, so we roll our own.
private struct PreviewModeSegmented: View {
    let mode: PreviewMode
    let hasStitched: Bool
    let onSelect: (PreviewMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            tab(label: "Full video", icon: "video.fill", value: .source, enabled: true)
            tab(label: "Final cut",  icon: "play.rectangle.fill", value: .finalCut, enabled: hasStitched)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func tab(label: String, icon: String, value: PreviewMode, enabled: Bool) -> some View {
        let isActive = mode == value
        return Button {
            if enabled { onSelect(value) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.callout)
            }
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(textColor(isActive: isActive, enabled: enabled))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minWidth: 110)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .shadow(color: isActive ? Color.black.opacity(0.12) : .clear, radius: 1, y: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "" : "Re-render the active script to enable Final cut.")
    }

    private func textColor(isActive: Bool, enabled: Bool) -> Color {
        if !enabled { return Color.secondary.opacity(0.45) }
        if isActive { return .primary }
        return .secondary
    }
}
