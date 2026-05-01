import Foundation

/// Transcribes audio using the bundled whisper-cli (whisper.cpp).
/// Requires a ggml model present at AppPaths.modelsDir/<modelName>.
final class WhisperLocalService: Transcriber {
    let modelName: String

    init(modelName: String) {
        self.modelName = modelName
    }

    var modelURL: URL { AppPaths.modelsDir.appendingPathComponent(modelName) }

    var isModelPresent: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    func transcribe(
        sourceVideo: URL,
        progress: @escaping (String) -> Void
    ) async throws -> Transcript {
        guard isModelPresent else {
            throw WhisperError.modelNotFound(modelURL)
        }

        // Extract mono 16kHz wav next to the source.
        let workDir = sourceVideo.deletingLastPathComponent()
        let audioWav = workDir.appendingPathComponent("audio.wav")
        progress("Extracting audio for transcription")
        try await FFmpegService.shared.extractAudio(from: sourceVideo, to: audioWav, progress: { _ in })

        // Run whisper-cli with JSON output (segment-level timestamps).
        let outBase = workDir.appendingPathComponent("transcript")
        progress("Transcribing with whisper.cpp (\(modelName))")
        try await BinaryRunner.shared.runChecked(
            "whisper-cli",
            args: [
                "-m", modelURL.path,
                "-f", audioWav.path,
                "-of", outBase.path,
                "-oj",            // output JSON (segment-level)
                "--print-progress",
                "--language", "auto",
                "--threads", String(max(2, ProcessInfo.processInfo.activeProcessorCount - 2)),
            ],
            onStdoutLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { progress(trimmed) }
            },
            onStderrLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.contains("progress") || trimmed.contains("error") {
                    progress(trimmed)
                }
            }
        )

        let jsonURL = outBase.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw WhisperError.parseError("whisper-cli did not produce \(jsonURL.lastPathComponent)")
        }

        let data = try Data(contentsOf: jsonURL)
        return try parseWhisperCppJSON(data)
    }

    /// whisper.cpp JSON format (top-level keys vary slightly between versions).
    /// We accept either a `transcription` array of {timestamps:{from,to}, offsets, text}
    /// or a `segments` array.
    private func parseWhisperCppJSON(_ data: Data) throws -> Transcript {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        var segments: [TranscriptSegment] = []
        var language: String?
        if let result = obj["result"] as? [String: Any] {
            language = result["language"] as? String
        }

        let segmentsRaw: [[String: Any]] = {
            if let arr = obj["transcription"] as? [[String: Any]] { return arr }
            if let arr = obj["segments"] as? [[String: Any]] { return arr }
            return []
        }()

        for (i, seg) in segmentsRaw.enumerated() {
            let text = (seg["text"] as? String) ?? ""
            // whisper.cpp gives timestamps in milliseconds inside `offsets`.
            let start: Double
            let end: Double
            if let offsets = seg["offsets"] as? [String: Any] {
                let from = (offsets["from"] as? Double) ?? Double((offsets["from"] as? Int) ?? 0)
                let to = (offsets["to"] as? Double) ?? Double((offsets["to"] as? Int) ?? 0)
                start = from / 1000.0
                end = to / 1000.0
            } else if let timestamps = seg["timestamps"] as? [String: Any] {
                start = parseTimestamp(timestamps["from"]) ?? 0
                end = parseTimestamp(timestamps["to"]) ?? 0
            } else {
                start = (seg["start"] as? Double) ?? 0
                end = (seg["end"] as? Double) ?? 0
            }
            segments.append(TranscriptSegment(id: i, start: start, end: end, text: text))
        }

        let duration = segments.last?.end ?? 0
        return Transcript(language: language, duration: duration, segments: segments, words: nil)
    }

    private func parseTimestamp(_ any: Any?) -> Double? {
        guard let s = any as? String else { return nil }
        // Format: "HH:MM:SS,mmm"
        let comps = s.split(separator: ":").map(String.init)
        guard comps.count == 3 else { return nil }
        let h = Double(comps[0]) ?? 0
        let m = Double(comps[1]) ?? 0
        let secMs = comps[2].replacingOccurrences(of: ",", with: ".")
        let s2 = Double(secMs) ?? 0
        return h * 3600 + m * 60 + s2
    }

    /// Download the model on first use. Calls progress with byte counts.
    func downloadModelIfNeeded(progress: @escaping (Double) -> Void) async throws {
        if isModelPresent { return }
        let url: URL = WhisperModel(rawValue: modelName)?.downloadURL ?? URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)")!
        let (tmpURL, response) = try await URLSession.shared.download(from: url, delegate: WhisperDownloadDelegate(progress: progress))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WhisperError.modelDownloadFailed("HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1 )")
        }
        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: tmpURL, to: modelURL)
    }
}

private final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // No-op; URLSession.download(from:) handles the location.
    }
}
