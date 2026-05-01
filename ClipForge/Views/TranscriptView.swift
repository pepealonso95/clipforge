import SwiftUI

/// Scrollable transcript with one row per segment.
/// - Tapping a row seeks the master player to that segment's start.
/// - Rows highlight when the player's currentTime is inside them.
/// - Rows show a colored bar when included in the active script's clips.
struct TranscriptView: View {
    let transcript: Transcript
    let currentTime: Double
    let activeScript: Script?
    let onSeek: (Double) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcript.segments, id: \.id) { seg in
                        TranscriptRow(
                            segment: seg,
                            isCurrent: isCurrent(seg),
                            inActiveClip: isInActiveClip(seg),
                            onTap: { onSeek(seg.start) }
                        )
                        .id(seg.id)
                    }
                }
                .padding(8)
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(inActiveClip ? Color.accentColor : Color.clear)
                    .frame(width: 3)
                Text(formatTimecode(segment.start))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.body)
                    .foregroundStyle(isCurrent ? .primary : (inActiveClip ? .primary : .secondary))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

extension TranscriptSegment: Identifiable {}
