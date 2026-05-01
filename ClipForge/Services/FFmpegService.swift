import Foundation

/// Wraps ffmpeg/ffprobe operations: probe, concat, extract audio, trim, stitch.
final class FFmpegService {
    static let shared = FFmpegService()

    struct ProbeResult: Codable {
        let codecName: String
        let width: Int
        let height: Int
        let avgFrameRate: String
        let sampleRate: Int?
        let duration: Double
    }

    /// Run ffprobe to get duration, codec, resolution, fps, audio sample rate.
    func probe(_ url: URL) async throws -> ProbeResult {
        let result = try await BinaryRunner.shared.runChecked(
            "ffprobe",
            args: [
                "-v", "error",
                "-print_format", "json",
                "-show_streams",
                "-show_format",
                url.path,
            ]
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw FFmpegError.probeFailed("ffprobe returned non-UTF8 output")
        }
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let streams = parsed["streams"] as? [[String: Any]] ?? []
        let format = parsed["format"] as? [String: Any] ?? [:]
        let video = streams.first(where: { ($0["codec_type"] as? String) == "video" })
        let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" })

        let codec = (video?["codec_name"] as? String) ?? "unknown"
        let width = (video?["width"] as? Int) ?? 0
        let height = (video?["height"] as? Int) ?? 0
        let fps = (video?["avg_frame_rate"] as? String) ?? (video?["r_frame_rate"] as? String) ?? "0/1"
        let sampleRate: Int? = {
            if let s = audio?["sample_rate"] as? String { return Int(s) }
            if let n = audio?["sample_rate"] as? Int { return n }
            return nil
        }()
        let duration: Double = {
            if let s = format["duration"] as? String, let d = Double(s) { return d }
            if let s = video?["duration"] as? String, let d = Double(s) { return d }
            return 0
        }()
        return ProbeResult(
            codecName: codec,
            width: width,
            height: height,
            avgFrameRate: fps,
            sampleRate: sampleRate,
            duration: duration
        )
    }

    /// Concatenate multiple inputs into a single H.264/AAC mov.
    /// If all sources match in codec/res/fps/sample_rate, use fast concat demuxer with `-c copy`.
    /// Otherwise re-encode all to a common intermediate (1920x1080@30 H.264 + AAC 48k).
    /// Returns segment offsets so timestamps in master can map back to source files.
    func concat(
        sources: [URL],
        masterOut: URL,
        progress: ((String) -> Void)? = nil
    ) async throws -> [SourceSegment] {
        precondition(!sources.isEmpty, "concat requires at least one source")

        var probes: [(URL, ProbeResult)] = []
        for src in sources {
            let probed = try await probe(src)
            probes.append((src, probed))
            progress?("Probed \(src.lastPathComponent): \(probed.codecName) \(probed.width)x\(probed.height) @ \(probed.avgFrameRate), \(String(format: "%.2f", probed.duration))s")
        }

        let allMatch: Bool = {
            guard let first = probes.first?.1 else { return false }
            return probes.allSatisfy { p in
                p.1.codecName == first.codecName
                    && p.1.width == first.width
                    && p.1.height == first.height
                    && p.1.avgFrameRate == first.avgFrameRate
                    && p.1.sampleRate == first.sampleRate
            }
        }()

        // Build segment offset map from durations.
        var segments: [SourceSegment] = []
        var cursor = 0.0
        for (url, p) in probes {
            let seg = SourceSegment(
                sourcePath: url.path,
                startInMaster: cursor,
                endInMaster: cursor + p.duration,
                duration: p.duration
            )
            segments.append(seg)
            cursor += p.duration
        }

        try? FileManager.default.removeItem(at: masterOut)

        if allMatch && sources.count > 1 {
            // Fast path: concat demuxer with -c copy
            let listURL = masterOut.deletingLastPathComponent().appendingPathComponent("concat_list.txt")
            let listBody = sources.map { "file '\(escapePath($0.path))'" }.joined(separator: "\n") + "\n"
            try listBody.write(to: listURL, atomically: true, encoding: .utf8)
            progress?("Fast concat (no re-encode) of \(sources.count) files")
            try await BinaryRunner.shared.runChecked(
                "ffmpeg",
                args: [
                    "-y",
                    "-hide_banner", "-loglevel", "warning",
                    "-f", "concat", "-safe", "0",
                    "-i", listURL.path,
                    "-c", "copy",
                    masterOut.path,
                ],
                onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
            )
            try? FileManager.default.removeItem(at: listURL)
        } else if sources.count == 1 {
            // Single file: just re-encode (or copy if container is fine). Re-encode keeps things consistent.
            progress?("Re-encoding single source to master timeline")
            try await reencode(source: sources[0], output: masterOut, progress: progress)
        } else {
            // Mixed codecs/resolutions: re-encode each to intermediate then concat.
            progress?("Re-encoding \(sources.count) files to common intermediate before concat")
            let tmpDir = masterOut.deletingLastPathComponent().appendingPathComponent("concat_tmp", isDirectory: true)
            try? FileManager.default.removeItem(at: tmpDir)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            var intermediates: [URL] = []
            for (i, src) in sources.enumerated() {
                let out = tmpDir.appendingPathComponent(String(format: "part_%03d.mov", i))
                progress?("Re-encoding part \(i+1)/\(sources.count): \(src.lastPathComponent)")
                try await reencode(source: src, output: out, progress: progress)
                intermediates.append(out)
            }
            let listURL = tmpDir.appendingPathComponent("list.txt")
            let listBody = intermediates.map { "file '\(escapePath($0.path))'" }.joined(separator: "\n") + "\n"
            try listBody.write(to: listURL, atomically: true, encoding: .utf8)
            progress?("Concatenating intermediates")
            try await BinaryRunner.shared.runChecked(
                "ffmpeg",
                args: [
                    "-y",
                    "-hide_banner", "-loglevel", "warning",
                    "-f", "concat", "-safe", "0",
                    "-i", listURL.path,
                    "-c", "copy",
                    masterOut.path,
                ],
                onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
            )
            try? FileManager.default.removeItem(at: tmpDir)
        }

        return segments
    }

    /// Re-encode a single source to 1920x1080@30 H.264 + AAC 48k (mov container).
    private func reencode(source: URL, output: URL, progress: ((String) -> Void)? = nil) async throws {
        try await BinaryRunner.shared.runChecked(
            "ffmpeg",
            args: [
                "-y",
                "-hide_banner", "-loglevel", "warning",
                "-i", source.path,
                "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,setsar=1",
                "-c:v", "libx264", "-preset", "fast", "-crf", "20",
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                output.path,
            ],
            onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    /// Extract mono 16kHz wav for whisper input.
    func extractAudio(from videoURL: URL, to audioWav: URL, progress: ((String) -> Void)? = nil) async throws {
        try? FileManager.default.removeItem(at: audioWav)
        try await BinaryRunner.shared.runChecked(
            "ffmpeg",
            args: [
                "-y",
                "-hide_banner", "-loglevel", "warning",
                "-i", videoURL.path,
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-acodec", "pcm_s16le",
                audioWav.path,
            ],
            onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    /// Extract a compressed mono opus for OpenAI API upload (under 25 MB for ~3 hours of speech).
    func extractCompressedAudio(from videoURL: URL, to audioOgg: URL, progress: ((String) -> Void)? = nil) async throws {
        try? FileManager.default.removeItem(at: audioOgg)
        try await BinaryRunner.shared.runChecked(
            "ffmpeg",
            args: [
                "-y",
                "-hide_banner", "-loglevel", "warning",
                "-i", videoURL.path,
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "libopus",
                "-b:a", "32k",
                audioOgg.path,
            ],
            onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    /// Trim a clip from the master timeline (sample-accurate via re-encode + audio fades).
    /// `-ss` placed AFTER `-i` for sample-accurate seeking. Adds 30 ms audio fade-in/out
    /// to soften hard cuts. Forces an IDR keyframe at the start of the clip.
    func trimClip(
        master: URL,
        startSeconds: Double,
        endSeconds: Double,
        output: URL,
        progress: ((String) -> Void)? = nil
    ) async throws {
        let duration = max(0.05, endSeconds - startSeconds)
        let fadeDuration = min(0.03, duration / 4.0)
        let fadeOutStart = max(0.0, duration - fadeDuration)
        let audioFilter = String(
            format: "afade=t=in:st=0:d=%.3f,afade=t=out:st=%.3f:d=%.3f",
            fadeDuration, fadeOutStart, fadeDuration
        )
        try? FileManager.default.removeItem(at: output)
        try await BinaryRunner.shared.runChecked(
            "ffmpeg",
            args: [
                "-y",
                "-hide_banner", "-loglevel", "warning",
                "-i", master.path,
                "-ss", String(format: "%.3f", startSeconds),
                "-t", String(format: "%.3f", duration),
                "-c:v", "libx264", "-preset", "fast", "-crf", "20",
                "-force_key_frames", "0",
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                "-af", audioFilter,
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                "-avoid_negative_ts", "make_zero",
                "-reset_timestamps", "1",
                output.path,
            ],
            onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    /// Single-pass stitch directly from master.mov via the concat filter.
    /// One ffmpeg invocation: decodes master once, applies trim+atrim+afade per clip,
    /// then concats and re-encodes the result. Eliminates PTS gaps and audio-boundary
    /// glitches that arise from concatenating independently-encoded clip files.
    func stitchFromMaster(
        master: URL,
        clips: [Clip],
        output: URL,
        progress: ((String) -> Void)? = nil
    ) async throws {
        precondition(!clips.isEmpty, "stitchFromMaster requires at least one clip")
        try? FileManager.default.removeItem(at: output)

        var graphParts: [String] = []
        for (i, clip) in clips.enumerated() {
            let s = clip.sourceStart
            let e = clip.sourceEnd
            let dur = max(0.05, e - s)
            let fadeDuration = min(0.03, dur / 4.0)
            let fadeOutStart = max(0.0, dur - fadeDuration)
            let v = String(
                format: "[0:v]trim=start=%.3f:end=%.3f,setpts=PTS-STARTPTS[v%d]",
                s, e, i
            )
            let a = String(
                format: "[0:a]atrim=start=%.3f:end=%.3f,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=%.3f,afade=t=out:st=%.3f:d=%.3f[a%d]",
                s, e, fadeDuration, fadeOutStart, fadeDuration, i
            )
            graphParts.append(v)
            graphParts.append(a)
        }
        let n = clips.count
        let concatInputs = (0..<n).map { "[v\($0)][a\($0)]" }.joined()
        graphParts.append("\(concatInputs)concat=n=\(n):v=1:a=1[v][a]")
        let filterGraph = graphParts.joined(separator: ";")

        try await BinaryRunner.shared.runChecked(
            "ffmpeg",
            args: [
                "-y",
                "-hide_banner", "-loglevel", "warning",
                "-i", master.path,
                "-filter_complex", filterGraph,
                "-map", "[v]", "-map", "[a]",
                "-c:v", "libx264", "-preset", "fast", "-crf", "20",
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                output.path,
            ],
            onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    /// Stitch a list of MP4 clips into one stitched.mp4 via concat demuxer.
    /// The clips were produced by `trimClip` with consistent encode params, so `-c copy` works.
    func stitch(
        clips: [URL],
        output: URL,
        progress: ((String) -> Void)? = nil
    ) async throws {
        precondition(!clips.isEmpty, "stitch requires at least one clip")
        try? FileManager.default.removeItem(at: output)
        let listURL = output.deletingLastPathComponent().appendingPathComponent(".stitch_list.txt")
        let listBody = clips.map { "file '\(escapePath($0.path))'" }.joined(separator: "\n") + "\n"
        try listBody.write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }
        try await BinaryRunner.shared.runChecked(
            "ffmpeg",
            args: [
                "-y",
                "-hide_banner", "-loglevel", "warning",
                "-f", "concat", "-safe", "0",
                "-i", listURL.path,
                "-c", "copy",
                "-movflags", "+faststart",
                output.path,
            ],
            onStderrLine: { line in progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    private func escapePath(_ path: String) -> String {
        // ffmpeg concat demuxer requires single-quoted paths with internal single quotes escaped.
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}

enum FFmpegError: LocalizedError {
    case probeFailed(String)

    var errorDescription: String? {
        switch self {
        case .probeFailed(let msg): return "ffprobe failed: \(msg)"
        }
    }
}
