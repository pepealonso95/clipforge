import SwiftUI
import AVKit

/// Right-side panel: script picker + editable clips list with extend/trim/delete/reorder.
struct ScriptEditorPane: View {
    @Binding var scripts: [Script]
    @Binding var selectedIndex: Int
    let transcript: Transcript
    let masterDuration: Double
    let onPlayClip: (Clip) -> Void
    let onRerender: () -> Void
    let isRendering: Bool
    let renderError: String?
    let stitchedURL: URL?
    let onRevealOutput: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if scripts.isEmpty {
                Text("No scripts").foregroundStyle(.secondary)
            } else {
                clipsList
                Divider()
                renderControls
                if let stitched = stitchedURL, FileManager.default.fileExists(atPath: stitched.path) {
                    StitchedPreview(url: stitched)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scripts").font(.headline)
                Spacer()
                Button { onRevealOutput() } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
            if !scripts.isEmpty {
                Picker("", selection: $selectedIndex) {
                    ForEach(Array(scripts.enumerated()), id: \.offset) { idx, s in
                        Text(s.name).tag(idx)
                    }
                }
                .labelsHidden()
                if scripts.indices.contains(selectedIndex) {
                    let s = scripts[selectedIndex]
                    HStack(spacing: 12) {
                        Label(s.theme, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("\(String(format: "%.1f", s.actualDuration))s / \(String(format: "%.1f", s.targetDurationSeconds))s",
                              systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(durationColor(actual: s.actualDuration, target: s.targetDurationSeconds))
                    }
                }
            }
        }
    }

    private var clipsList: some View {
        let bind = Binding<[Clip]>(
            get: { scripts.indices.contains(selectedIndex) ? scripts[selectedIndex].clips : [] },
            set: { newClips in
                if scripts.indices.contains(selectedIndex) {
                    scripts[selectedIndex].clips = newClips
                }
            }
        )
        return List {
            ForEach(bind, id: \.id) { $clip in
                ClipRow(
                    clip: $clip,
                    transcript: transcript,
                    masterDuration: masterDuration,
                    onPlay: { onPlayClip(clip) },
                    onDelete: { deleteClip(id: clip.id) }
                )
            }
            .onMove(perform: moveClips)
        }
        .listStyle(.inset)
        .frame(minHeight: 200, maxHeight: 380)
    }

    private var renderControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: onRerender) {
                    if isRendering {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Rendering…")
                        }
                    } else {
                        Label("Save & Re-render", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRendering)
                Spacer()
            }
            if let renderError {
                Text(renderError).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    // MARK: - Actions

    private func moveClips(from source: IndexSet, to destination: Int) {
        guard scripts.indices.contains(selectedIndex) else { return }
        scripts[selectedIndex].clips.move(fromOffsets: source, toOffset: destination)
    }

    private func deleteClip(id: UUID) {
        guard scripts.indices.contains(selectedIndex) else { return }
        scripts[selectedIndex].clips.removeAll { $0.id == id }
    }

    private func durationColor(actual: Double, target: Double) -> Color {
        let ratio = actual / max(target, 0.01)
        if ratio < 0.7 || ratio > 1.3 { return .orange }
        return .secondary
    }
}

private struct ClipRow: View {
    @Binding var clip: Clip
    let transcript: Transcript
    let masterDuration: Double
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(formatTimecode(clip.sourceStart))–\(formatTimecode(clip.sourceEnd))  ·  \(String(format: "%.2f", clip.duration))s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Play this clip in the master player")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this clip from the script")
            }
            Text(clip.verbatim.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .lineLimit(4)
            HStack(spacing: 6) {
                Button { extendStart(by: -1) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Extend start: include the previous segment")
                Button { trimStart(by: 1) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Trim start: drop the first segment")
                Spacer().frame(width: 12)
                Button { trimEnd(by: -1) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Trim end: drop the last segment")
                    .rotationEffect(.degrees(180))
                Button { extendEnd(by: 1) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Extend end: include the next segment")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func extendStart(by direction: Int) {
        guard let prev = previousSegment(before: clip.sourceStart) else { return }
        clip.sourceStart = max(0, prev.start)
        refreshVerbatim()
    }

    private func trimStart(by direction: Int) {
        guard let first = firstSegmentInClip(), let next = segmentAfter(first) else { return }
        clip.sourceStart = next.start
        refreshVerbatim()
    }

    private func extendEnd(by direction: Int) {
        guard let next = nextSegment(after: clip.sourceEnd) else { return }
        clip.sourceEnd = min(masterDuration, next.end)
        refreshVerbatim()
    }

    private func trimEnd(by direction: Int) {
        guard let last = lastSegmentInClip(), let prev = segmentBefore(last) else { return }
        clip.sourceEnd = prev.end
        refreshVerbatim()
    }

    // MARK: - Segment lookup helpers

    private func previousSegment(before time: Double) -> TranscriptSegment? {
        transcript.segments.last(where: { $0.end <= time + 0.01 })
    }

    private func nextSegment(after time: Double) -> TranscriptSegment? {
        transcript.segments.first(where: { $0.start >= time - 0.01 })
    }

    private func firstSegmentInClip() -> TranscriptSegment? {
        transcript.segments.first(where: { $0.start >= clip.sourceStart - 0.01 && $0.end <= clip.sourceEnd + 0.01 })
    }

    private func lastSegmentInClip() -> TranscriptSegment? {
        transcript.segments.last(where: { $0.start >= clip.sourceStart - 0.01 && $0.end <= clip.sourceEnd + 0.01 })
    }

    private func segmentAfter(_ s: TranscriptSegment) -> TranscriptSegment? {
        transcript.segments.first(where: { $0.start > s.start + 0.001 })
    }

    private func segmentBefore(_ s: TranscriptSegment) -> TranscriptSegment? {
        transcript.segments.last(where: { $0.start < s.start - 0.001 })
    }

    private func refreshVerbatim() {
        let inside = transcript.segments
            .filter { $0.start >= clip.sourceStart - 0.01 && $0.end <= clip.sourceEnd + 0.01 }
        let combined = inside
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        if !combined.isEmpty {
            clip.verbatim = combined
        }
    }
}

private struct StitchedPreview: View {
    let url: URL
    @State private var refreshKey: Date = Date()
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        self._player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stitched preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    player.pause()
                    player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    refreshKey = Date()
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help("Reload after re-render")
            }
            // Reload the AVPlayerItem to pick up freshly-rendered output.
            AVPlayerViewRepresentable(player: player)
                .frame(minHeight: 180)
                .background(Color.black)
                .cornerRadius(6)
                .id(refreshKey)
        }
    }
}
