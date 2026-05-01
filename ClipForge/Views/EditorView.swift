import SwiftUI
import AVKit
import AppKit

/// Editor mode: shown after a successful pipeline run. Lets the user scrub the
/// master video, navigate via the transcript, edit each script's clips, and
/// re-render without calling the AI again.
struct EditorView: View {
    @Binding var artifacts: PipelineArtifacts
    let onBackToSetup: () -> Void

    @StateObject private var playerCtrl: PlayerController
    @State private var selectedScriptIndex: Int = 0
    @State private var isRendering: Bool = false
    @State private var renderError: String? = nil
    @State private var lastRenderedAt: Date? = nil

    init(artifacts: Binding<PipelineArtifacts>, onBackToSetup: @escaping () -> Void) {
        self._artifacts = artifacts
        self.onBackToSetup = onBackToSetup
        self._playerCtrl = StateObject(wrappedValue: PlayerController(url: artifacts.wrappedValue.masterURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                leftPane
                    .frame(minWidth: 460, idealWidth: 560)
                ScriptEditorPane(
                    scripts: $artifacts.scripts,
                    selectedIndex: $selectedScriptIndex,
                    transcript: artifacts.transcript,
                    masterDuration: artifacts.masterDuration,
                    onPlayClip: { clip in
                        playerCtrl.playClip(start: clip.sourceStart, end: clip.sourceEnd)
                    },
                    onRerender: rerenderCurrent,
                    isRendering: isRendering,
                    renderError: renderError,
                    stitchedURL: stitchedURLForCurrent(),
                    onRevealOutput: revealOutput
                )
                .frame(minWidth: 380, idealWidth: 460)
            }
        }
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: onBackToSetup) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 18)
            Text(artifacts.projectRoot.lastPathComponent)
                .font(.headline)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(artifacts.scripts.count) script(s) · \(String(format: "%.1f", artifacts.masterDuration))s master")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let lastRenderedAt {
                Text("Re-rendered \(timeAgo(lastRenderedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var leftPane: some View {
        VStack(spacing: 8) {
            AVPlayerViewRepresentable(player: playerCtrl.player)
                .frame(minHeight: 280)
                .background(Color.black)
                .cornerRadius(6)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            HStack(spacing: 12) {
                Text(formatTimecode(playerCtrl.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { playerCtrl.currentTime },
                        set: { newValue in
                            playerCtrl.currentTime = newValue
                            playerCtrl.seek(to: newValue)
                        }
                    ),
                    in: 0...max(artifacts.masterDuration, 0.01)
                )
                Text(formatTimecode(artifacts.masterDuration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)

            TranscriptView(
                transcript: artifacts.transcript,
                currentTime: playerCtrl.currentTime,
                activeScript: currentScript,
                onSeek: { t in
                    playerCtrl.seek(to: t)
                    playerCtrl.play()
                }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .onAppear { attachTimeObserver() }
    }

    // MARK: - State

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

    // MARK: - Actions

    private func revealOutput() {
        if let url = stitchedURLForCurrent()?.deletingLastPathComponent(),
           FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([artifacts.projectRoot])
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
