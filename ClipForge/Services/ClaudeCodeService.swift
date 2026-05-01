import Foundation

/// Invokes the Claude Code CLI in headless `-p` mode.
final class ClaudeCodeService: AIRunner {
    let name = "Claude Code"
    let yolo: Bool

    init(yolo: Bool = false) {
        self.yolo = yolo
    }

    func runRaw(
        prompt: String,
        progress: @escaping (String) -> Void
    ) async throws -> (stdout: String, stderr: String) {
        progress("Calling Claude Code (headless)…")

        var args: [String] = ["-p"]
        if yolo {
            args.append("--dangerously-skip-permissions")
        }

        let result = try await BinaryRunner.shared.run(
            "claude",
            args: args,
            stdinData: prompt.data(using: .utf8) ?? Data(),
            onStderrLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { progress(trimmed) }
            }
        )

        if result.exitCode != 0 {
            throw AICliError.cliFailed("claude exited \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return (stdout: result.stdout, stderr: result.stderr)
    }
}
