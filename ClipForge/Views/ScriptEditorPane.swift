import SwiftUI

/// Right-side pane for the active script: header (name/theme/duration), clips
/// list, and the Save & Re-render action. Script selection happens in the
/// top-level tab bar; mode switching (source vs final cut) lives on the player.
struct ScriptEditorPane: View {
    @Binding var scripts: [Script]
    let selectedIndex: Int
    /// True when the active script has unsaved changes since the last render.
    /// Drives the Save & Re-render enabled/disabled appearance.
    let isDirty: Bool
    let onPlayClip: (Clip) -> Void
    let onRerender: () -> Void
    let isRendering: Bool
    let renderError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            clipsList
            Divider()
            renderControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        if let s = currentScript {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.name)
                    .font(.title3).fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !s.theme.isEmpty {
                    Text(s.theme)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                durationBlock(s: s)
            }
            .padding(14)
        } else {
            Text("No script selected")
                .foregroundStyle(.secondary)
                .padding(14)
        }
    }

    private func durationBlock(s: Script) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Duration").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(String(format: "%.1f", s.actualDuration))s / \(String(format: "%.1f", s.targetDurationSeconds))s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(durationColor(actual: s.actualDuration, target: s.targetDurationSeconds))
            }
            ProgressView(
                value: min(s.actualDuration / max(s.targetDurationSeconds, 0.01), 1.5),
                total: 1.5
            )
            .tint(durationColor(actual: s.actualDuration, target: s.targetDurationSeconds))
        }
    }

    @ViewBuilder
    private var clipsList: some View {
        let bind = clipsBinding
        if bind.wrappedValue.isEmpty {
            emptyClips
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(bind, id: \.id) { $clip in
                    ClipRow(
                        clip: $clip,
                        onPlay: { onPlayClip(clip) },
                        onDelete: { deleteClip(id: clip.id) }
                    )
                }
                .onMove(perform: moveClips)
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyClips: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No clips in this script yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Click segments in the transcript to add them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var renderControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onRerender) {
                if isRendering {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Rendering…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Save & Re-render", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRendering || currentClipsEmpty || !isDirty)
            .help(disabledHelp)

            if let renderError {
                Text(renderError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(14)
    }

    // MARK: - Derived

    private var currentScript: Script? {
        scripts.indices.contains(selectedIndex) ? scripts[selectedIndex] : nil
    }

    private var currentClipsEmpty: Bool {
        currentScript?.clips.isEmpty ?? true
    }

    private var disabledHelp: String {
        if isRendering { return "Rendering…" }
        if currentClipsEmpty { return "Add clips from the transcript to enable rendering." }
        if !isDirty { return "No changes since the last render." }
        return ""
    }

    private var clipsBinding: Binding<[Clip]> {
        Binding<[Clip]>(
            get: { scripts.indices.contains(selectedIndex) ? scripts[selectedIndex].clips : [] },
            set: { newClips in
                if scripts.indices.contains(selectedIndex) {
                    scripts[selectedIndex].clips = newClips
                }
            }
        )
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
                .help("Play this clip")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this clip from the script")
            }
            Text(clip.verbatim.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .lineLimit(4)
        }
        .padding(.vertical, 4)
    }
}
