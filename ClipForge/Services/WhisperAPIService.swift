import Foundation

/// Transcribes audio via OpenAI Whisper API (`/v1/audio/transcriptions`, model whisper-1).
/// Re-encodes audio to mono 16k opus to keep upload under 25 MB.
final class WhisperAPIService: Transcriber {
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(
        sourceVideo: URL,
        progress: @escaping (String) -> Void
    ) async throws -> Transcript {
        guard !apiKey.isEmpty else { throw WhisperError.missingAPIKey }

        let workDir = sourceVideo.deletingLastPathComponent()
        let audioOgg = workDir.appendingPathComponent("audio.ogg")
        progress("Compressing audio for OpenAI upload")
        try await FFmpegService.shared.extractCompressedAudio(from: sourceVideo, to: audioOgg, progress: { _ in })

        progress("Uploading to OpenAI Whisper API")
        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "----ClipForge-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try buildMultipart(
            boundary: boundary,
            file: audioOgg,
            fields: [
                "model": "whisper-1",
                "response_format": "verbose_json",
                "timestamp_granularities[]": "segment",
            ]
        )

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.apiError(-1, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw WhisperError.apiError(http.statusCode, bodyStr)
        }

        return try parseOpenAIVerboseJSON(data)
    }

    private func buildMultipart(boundary: String, file: URL, fields: [String: String]) throws -> Data {
        var data = Data()
        let crlf = "\r\n".data(using: .utf8)!

        for (k, v) in fields {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            data.append(v.data(using: .utf8)!)
            data.append(crlf)
        }

        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: audio/ogg\r\n\r\n".data(using: .utf8)!)
        data.append(try Data(contentsOf: file))
        data.append(crlf)

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    private func parseOpenAIVerboseJSON(_ data: Data) throws -> Transcript {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let language = obj["language"] as? String
        let duration: Double = (obj["duration"] as? Double) ?? Double((obj["duration"] as? Int) ?? 0)
        let segArr = (obj["segments"] as? [[String: Any]]) ?? []
        var segments: [TranscriptSegment] = []
        for (i, seg) in segArr.enumerated() {
            let text = (seg["text"] as? String) ?? ""
            let start = (seg["start"] as? Double) ?? 0
            let end = (seg["end"] as? Double) ?? 0
            segments.append(TranscriptSegment(id: (seg["id"] as? Int) ?? i, start: start, end: end, text: text))
        }
        return Transcript(language: language, duration: duration, segments: segments, words: nil)
    }
}
