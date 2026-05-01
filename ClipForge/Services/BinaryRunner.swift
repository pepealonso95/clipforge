import Foundation

struct BinaryRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum BinaryRunnerError: LocalizedError {
    case binaryNotFound(name: String)
    case nonZeroExit(name: String, code: Int32, stderr: String)
    case launchFailed(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "Could not find executable '\(name)'. Tried app bundle, /opt/homebrew/bin, /usr/local/bin, and PATH."
        case .nonZeroExit(let name, let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(trimmed.suffix(800))
            return "\(name) exited with code \(code).\n\(tail)"
        case .launchFailed(let name, let underlying):
            return "Failed to launch \(name): \(underlying.localizedDescription)"
        }
    }
}

/// Resolves binaries (bundled first, then Homebrew, then PATH) and runs them via Process.
final class BinaryRunner {
    static let shared = BinaryRunner()

    private static let extraSearchPaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
        ]
    }()

    /// Resolve a binary by name. Order:
    /// 1. App bundle Resources/Bin/<name> (if executable)
    /// 2. /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, etc.
    /// 3. Whatever's on the user's PATH (looked up via /usr/bin/which from a login shell)
    func resolve(_ name: String) -> URL? {
        if let bundled = AppPaths.bundledBinary(name),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for dir in Self.extraSearchPaths {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Run a named executable and capture stdout/stderr.
    @discardableResult
    func run(
        _ name: String,
        args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        stdinData: Data? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> BinaryRunResult {
        guard let url = resolve(name) else {
            throw BinaryRunnerError.binaryNotFound(name: name)
        }
        return try await runProcess(
            executable: url,
            args: args,
            cwd: cwd,
            env: env,
            stdinData: stdinData,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine
        )
    }

    /// Same as `run` but throws on non-zero exit.
    @discardableResult
    func runChecked(
        _ name: String,
        args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        stdinData: Data? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> BinaryRunResult {
        let result = try await run(
            name,
            args: args,
            cwd: cwd,
            env: env,
            stdinData: stdinData,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine
        )
        if result.exitCode != 0 {
            throw BinaryRunnerError.nonZeroExit(name: name, code: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    func runProcess(
        executable: URL,
        args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        stdinData: Data? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> BinaryRunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        var processEnv = ProcessInfo.processInfo.environment
        let injectedPath = Self.extraSearchPaths.joined(separator: ":")
        if let existing = processEnv["PATH"], !existing.isEmpty {
            processEnv["PATH"] = "\(injectedPath):\(existing)"
        } else {
            processEnv["PATH"] = injectedPath
        }
        if let env { for (k, v) in env { processEnv[k] = v } }
        process.environment = processEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe? = stdinData != nil ? Pipe() : nil
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe { process.standardInput = stdinPipe }

        let stdoutBox = ByteBuffer()
        let stderrBox = ByteBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            stdoutBox.append(data)
            if let onStdoutLine, let s = String(data: data, encoding: .utf8) {
                onStdoutLine(s)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            stderrBox.append(data)
            if let onStderrLine, let s = String(data: data, encoding: .utf8) {
                onStderrLine(s)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BinaryRunResult, Error>) in
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let outStr = stdoutBox.asString()
                    let errStr = stderrBox.asString()
                    cont.resume(returning: BinaryRunResult(
                        exitCode: proc.terminationStatus,
                        stdout: outStr,
                        stderr: errStr
                    ))
                }

                do {
                    try process.run()
                    if let stdinPipe, let data = stdinData {
                        let writer = stdinPipe.fileHandleForWriting
                        do {
                            try writer.write(contentsOf: data)
                            try writer.close()
                        } catch {
                            // Best-effort: terminate; termination handler will fire and resume.
                            process.terminate()
                        }
                    }
                } catch {
                    process.terminationHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: BinaryRunnerError.launchFailed(name: executable.lastPathComponent, underlying: error))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// Thread-safe byte accumulator for piping output.
final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func asString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
