import Foundation

/// Invokes the Codex CLI in headless `exec` mode.
final class CodexService: AIRunner {
    let name = "Codex"
    let yolo: Bool

    init(yolo: Bool = false) {
        self.yolo = yolo
    }

    func runRaw(
        prompt: String,
        progress: @escaping (String) -> Void
    ) async throws -> (stdout: String, stderr: String) {
        progress("Calling Codex (exec)…")

        var args: [String] = ["exec"]
        if yolo {
            args.append("--full-auto")
        }
        // Read prompt from stdin
        args.append("-")

        let result = try await BinaryRunner.shared.run(
            "codex",
            args: args,
            stdinData: prompt.data(using: .utf8) ?? Data(),
            onStderrLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { progress(trimmed) }
            }
        )

        if result.exitCode != 0 {
            throw AICliError.cliFailed("codex exited \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return (stdout: result.stdout, stderr: result.stderr)
    }
}
