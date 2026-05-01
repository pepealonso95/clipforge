import Foundation

/// Runs an AI CLI in headless mode and returns its raw stdout/stderr.
/// Parsing + repair + retry is the caller's responsibility (Pipeline).
protocol AIRunner {
    var name: String { get }

    func runRaw(
        prompt: String,
        progress: @escaping (String) -> Void
    ) async throws -> (stdout: String, stderr: String)
}

enum AICliError: LocalizedError {
    case invalidJSON(String, raw: String)
    case retryExhausted(String)
    case cliFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let msg, let raw):
            let head = String(raw.prefix(400))
            return "AI returned invalid JSON: \(msg)\n\nFirst 400 chars of response:\n\(head)"
        case .retryExhausted(let msg): return "AI retry exhausted: \(msg)"
        case .cliFailed(let msg): return "AI CLI failed: \(msg)"
        }
    }
}
