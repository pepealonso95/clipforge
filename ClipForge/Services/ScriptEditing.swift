import Foundation

/// Direct-manipulation editing for `Script.clips` driven by transcript segments.
///
/// The user clicks a transcript row to add or remove that segment from the
/// active script. Adjacent included segments coalesce into one clip; removing
/// a segment from the middle of a clip splits it into two.
extension Script {
    /// Toggle the inclusion of a transcript segment in this script's clips.
    mutating func toggleSegment(_ segment: TranscriptSegment, transcript: Transcript) {
        let s = segment.start
        let e = segment.end
        let tol = 0.02

        if let idx = clips.firstIndex(where: { $0.sourceStart <= s + tol && $0.sourceEnd >= e - tol }) {
            removeRange(start: s, end: e, fromClipAt: idx, transcript: transcript, tol: tol)
        } else {
            addSegment(start: s, end: e, fallbackText: segment.text, transcript: transcript, tol: tol)
        }

        clips.sort { $0.sourceStart < $1.sourceStart }
    }

    private mutating func removeRange(
        start s: Double,
        end e: Double,
        fromClipAt idx: Int,
        transcript: Transcript,
        tol: Double
    ) {
        let clip = clips[idx]
        let atStart = abs(clip.sourceStart - s) < tol
        let atEnd = abs(clip.sourceEnd - e) < tol

        switch (atStart, atEnd) {
        case (true, true):
            clips.remove(at: idx)
        case (true, false):
            clips[idx].sourceStart = e
            refreshVerbatim(at: idx, transcript: transcript)
        case (false, true):
            clips[idx].sourceEnd = s
            refreshVerbatim(at: idx, transcript: transcript)
        case (false, false):
            // Split into two clips around the removed segment.
            var left = clip
            left.sourceEnd = s
            var right = clip
            right.id = UUID()
            right.sourceStart = e
            // The right half doesn't keep the section header (it stays with left).
            right.sectionHeader = nil
            clips[idx] = left
            clips.insert(right, at: idx + 1)
            refreshVerbatim(at: idx, transcript: transcript)
            refreshVerbatim(at: idx + 1, transcript: transcript)
        }
    }

    private mutating func addSegment(
        start s: Double,
        end e: Double,
        fallbackText: String,
        transcript: Transcript,
        tol: Double
    ) {
        // Extend an adjacent clip if one ends at s or starts at e.
        if let idx = clips.firstIndex(where: { abs($0.sourceEnd - s) < tol }) {
            clips[idx].sourceEnd = e
            refreshVerbatim(at: idx, transcript: transcript)
        } else if let idx = clips.firstIndex(where: { abs($0.sourceStart - e) < tol }) {
            clips[idx].sourceStart = s
            refreshVerbatim(at: idx, transcript: transcript)
        } else {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            clips.append(Clip(sourceStart: s, sourceEnd: e, verbatim: trimmed))
        }
        coalesce(transcript: transcript, tol: tol)
    }

    /// Merge any clips whose ranges touch (within `tol`).
    private mutating func coalesce(transcript: Transcript, tol: Double) {
        clips.sort { $0.sourceStart < $1.sourceStart }
        var i = 0
        while i + 1 < clips.count {
            if clips[i + 1].sourceStart - clips[i].sourceEnd < tol {
                clips[i].sourceEnd = max(clips[i].sourceEnd, clips[i + 1].sourceEnd)
                clips.remove(at: i + 1)
                refreshVerbatim(at: i, transcript: transcript)
            } else {
                i += 1
            }
        }
    }

    private mutating func refreshVerbatim(at idx: Int, transcript: Transcript) {
        guard clips.indices.contains(idx) else { return }
        let c = clips[idx]
        let inside = transcript.segments.filter {
            $0.start >= c.sourceStart - 0.01 && $0.end <= c.sourceEnd + 0.01
        }
        let combined = inside
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        if !combined.isEmpty {
            clips[idx].verbatim = combined
        }
    }
}
