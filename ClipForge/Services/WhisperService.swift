import Foundation

protocol Transcriber {
    /// Transcribe a video/audio file. The implementation handles audio extraction if needed.
    func transcribe(
        sourceVideo: URL,
        progress: @escaping (String) -> Void
    ) async throws -> Transcript
}

enum WhisperError: LocalizedError {
    case modelNotFound(URL)
    case modelDownloadFailed(String)
    case missingAPIKey
    case apiError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let url): return "Whisper model not found at \(url.path). Download from Settings."
        case .modelDownloadFailed(let msg): return "Whisper model download failed: \(msg)"
        case .missingAPIKey: return "OpenAI API key is required for API mode. Set it in Settings."
        case .apiError(let code, let body): return "OpenAI API error \(code): \(body)"
        case .parseError(let msg): return "Could not parse transcript: \(msg)"
        }
    }
}
