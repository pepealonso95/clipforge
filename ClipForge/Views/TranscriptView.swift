import SwiftUI

/// Scrollable transcript with one row per segment.
/// - Click the timecode to seek the master player to that segment's start.
/// - Click the row text to add/remove the segment from the active script.
/// - The current playhead segment highlights in source mode.
struct TranscriptView: View {
    let transcript: Transcript
    let currentTime: Double
    let activeScript: Script?
    let onSeek: (Double) -> Void
    let onToggle: (TranscriptSegment) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcript.segments, id: \.id) { seg in
                        TranscriptRow(
                            segment: seg,
                            isCurrent: isCurrent(seg),
                            inActiveClip: isInActiveClip(seg),
                            hasActiveScript: activeScript != nil,
                            onSeek: { onSeek(seg.start) },
                            onToggle: { onToggle(seg) }
                        )
                        .id(seg.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: currentSegmentID) { _, newID in
                if let id = newID {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var currentSegmentID: Int? {
        transcript.segments.first(where: { $0.start <= currentTime && $0.end > currentTime })?.id
    }

    private func isCurrent(_ s: TranscriptSegment) -> Bool {
        s.start <= currentTime && s.end > currentTime
    }

    private func isInActiveClip(_ s: TranscriptSegment) -> Bool {
        guard let script = activeScript else { return false }
        return script.clips.contains { clip in
            s.start >= clip.sourceStart - 0.01 && s.end <= clip.sourceEnd + 0.01
        }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    let inActiveClip: Bool
    let hasActiveScript: Bool
    let onSeek: () -> Void
    let onToggle: () -> Void

    @State private var hovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(inActiveClip ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .padding(.trailing, 10)

            Text(formatTimecode(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(timecodeColor)
                .frame(width: 56, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onSeek() }
                .help("Seek to this segment")

            Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.body)
                .fontWeight(inActiveClip ? .medium : .regular)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if hasActiveScript { onToggle() } }
                .help(toggleHelp)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovered = $0 }
    }

    private var timecodeColor: Color {
        if isCurrent { return Color.accentColor }
        return .secondary
    }

    private var textColor: Color {
        if isCurrent { return .primary }
        return inActiveClip ? .primary : .secondary
    }

    private var rowBackground: Color {
        if isCurrent { return Color.accentColor.opacity(0.15) }
        if inActiveClip { return Color.accentColor.opacity(0.04) }
        if hovered { return Color.secondary.opacity(0.06) }
        return Color.clear
    }

    private var toggleHelp: String {
        guard hasActiveScript else { return "" }
        return inActiveClip ? "Remove from active script" : "Add to active script"
    }
}

extension TranscriptSegment: Identifiable {}
