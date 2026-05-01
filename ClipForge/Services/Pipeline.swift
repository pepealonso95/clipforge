import Foundation

enum PipelineStage: String, CaseIterable {
    case ingest = "Ingest"
    case concat = "Concatenate"
    case audio = "Extract audio"
    case transcribe = "Transcribe"
    case generate = "Generate scripts"
    case render = "Render outputs"
}

struct PipelineProgress {
    let stage: PipelineStage
    let message: String
    /// Optional 0…1 progress within the current stage.
    let fraction: Double?
}

/// Everything a finished pipeline run produces, packaged for the editor.
struct PipelineArtifacts {
    var projectRoot: URL
    var masterURL: URL
    var masterDuration: Double
    var transcript: Transcript
    var scripts: [Script]                         // mutable in editor
    var segments: [SourceSegment]
    var renderResults: [RenderResult]             // initial render
    var paths: ProjectPaths
}

@MainActor
final class Pipeline: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var currentStage: PipelineStage? = nil
    @Published var log: [String] = []
    @Published var error: Error? = nil
    @Published var results: [RenderResult] = []
    @Published var artifacts: PipelineArtifacts? = nil

    private var task: Task<Void, Never>?
    private var logger: SessionLogger?

    func cancel() {
        task?.cancel()
    }

    func run(inputs: ProjectInputs, settings: AppSettings) {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        log = []
        results = []
        artifacts = nil

        let snapshot = (
            whisperMode: settings.whisperMode,
            aiCli: settings.effectiveAICli,
            apiKey: settings.openaiAPIKey,
            modelName: settings.whisperModel.rawValue,
            yolo: settings.yoloMode
        )

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.execute(inputs: inputs, snapshot: snapshot)
            } catch {
                if Task.isCancelled {
                    self.append("Cancelled.")
                } else {
                    self.error = error
                    self.append("ERROR: \(error.localizedDescription)")
                }
            }
            self.isRunning = false
            self.currentStage = nil
        }
    }

    private func append(_ line: String) {
        log.append(line)
        logger?.log(line)
    }

    private func execute(
        inputs: ProjectInputs,
        snapshot: (
            whisperMode: WhisperMode,
            aiCli: AICliKind,
            apiKey: String,
            modelName: String,
            yolo: Bool
        )
    ) async throws {
        // STAGE 1: Ingest
        currentStage = .ingest
        let projectRoot = inputs.outputDirectory.appendingPathComponent(inputs.projectName, isDirectory: true)
        let paths = ProjectPaths(root: projectRoot)
        try paths.ensureDirectories()

        // Initialize per-session logger before any other appends.
        do {
            let sessionLogger = try SessionLogger(projectPaths: paths, projectName: inputs.projectName)
            self.logger = sessionLogger
            append("Session log:  \(sessionLogger.projectLogURL.path)")
            append("Global log:   \(sessionLogger.globalLogURL.path)")
        } catch {
            append("WARN: failed to open session log: \(error.localizedDescription)")
        }

        append("Settings: whisper=\(snapshot.whisperMode.rawValue), aiCli=\(snapshot.aiCli.rawValue), yolo=\(snapshot.yolo), model=\(snapshot.modelName)")
        append("Project root: \(projectRoot.path)")
        append("Inputs: \(inputs.sourceFiles.count) file(s)")
        for f in inputs.sourceFiles {
            append("  • \(f.lastPathComponent)")
        }

        try Task.checkCancellation()

        // STAGE 2: Concat
        currentStage = .concat
        append("--- Concatenating sources ---")
        let segments = try await FFmpegService.shared.concat(
            sources: inputs.sourceFiles,
            masterOut: paths.masterMov,
            progress: { [weak self] line in Task { @MainActor in self?.append(line) } }
        )
        let segData = try JSONEncoder().encode(segments)
        try segData.write(to: paths.segmentsJSON)

        try Task.checkCancellation()

        // STAGE 3: Audio extract — handled inside transcriber, but we'll record an info message.
        currentStage = .audio

        // STAGE 4: Transcribe
        currentStage = .transcribe
        append("--- Transcribing (\(snapshot.whisperMode.displayName)) ---")
        let transcriber: Transcriber
        switch snapshot.whisperMode {
        case .local:
            let svc = WhisperLocalService(modelName: snapshot.modelName)
            if !svc.isModelPresent {
                append("Whisper model not present at \(svc.modelURL.path)")
                append("Downloading model \(snapshot.modelName)…")
                try await svc.downloadModelIfNeeded { [weak self] frac in
                    Task { @MainActor in self?.append("  download \(Int(frac * 100))%") }
                }
            }
            transcriber = svc
        case .openAI:
            transcriber = WhisperAPIService(apiKey: snapshot.apiKey)
        }

        let transcript = try await transcriber.transcribe(
            sourceVideo: paths.masterMov,
            progress: { [weak self] line in Task { @MainActor in self?.append(line) } }
        )
        let transcriptData = try JSONEncoder().encode(transcript)
        try transcriptData.write(to: paths.transcriptJSON)
        append("Transcript: \(transcript.segments.count) segments, \(String(format: "%.1f", transcript.duration ?? 0))s")

        try Task.checkCancellation()

        // STAGE 5: Generate scripts
        currentStage = .generate
        append("--- Generating scripts (\(snapshot.aiCli.displayName)\(snapshot.yolo ? ", YOLO" : "")) ---")
        let runner: AIRunner = (snapshot.aiCli == .claude)
            ? ClaudeCodeService(yolo: snapshot.yolo)
            : CodexService(yolo: snapshot.yolo)

        let masterDuration = transcript.duration ?? segments.reduce(0.0) { $0 + $1.duration }
        let prompt = PromptBuilder.buildPrompt(
            userSpec: inputs.userPrompt,
            transcript: transcript,
            masterDuration: masterDuration
        )

        // Save the prompt for self-debugging the AI's behavior.
        try? prompt.write(to: paths.aiPrompt, atomically: true, encoding: .utf8)
        append("Prompt saved:    \(paths.aiPrompt.lastPathComponent) (\(prompt.count) chars)")

        let progressCallback: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }

        let raw = try await runner.runRaw(prompt: prompt, progress: progressCallback)
        try? raw.stdout.write(to: paths.aiResponseRaw, atomically: true, encoding: .utf8)
        try? raw.stderr.write(to: paths.aiStderr, atomically: true, encoding: .utf8)
        append("AI response:     \(paths.aiResponseRaw.lastPathComponent) (\(raw.stdout.count) chars)")

        let scripts: [Script]
        do {
            scripts = try ScriptParser.parseScripts(from: raw.stdout, attemptRepair: true)
        } catch let firstError {
            append("WARN: AI response did not parse cleanly: \(firstError.localizedDescription)")
            append("Asking \(runner.name) to retry with stricter instructions…")

            let retryPrompt = buildRetryPrompt(
                originalPrompt: prompt,
                badResponse: raw.stdout,
                error: firstError
            )
            try? retryPrompt.write(to: paths.aiPromptRetry, atomically: true, encoding: .utf8)

            let raw2 = try await runner.runRaw(prompt: retryPrompt, progress: progressCallback)
            try? raw2.stdout.write(to: paths.aiResponseRawRetry, atomically: true, encoding: .utf8)
            try? raw2.stderr.write(to: paths.aiStderrRetry, atomically: true, encoding: .utf8)
            append("AI retry response: \(paths.aiResponseRawRetry.lastPathComponent) (\(raw2.stdout.count) chars)")

            scripts = try ScriptParser.parseScripts(from: raw2.stdout, attemptRepair: true)
        }
        let scriptsData = try JSONEncoder().encode(ScriptResponse(scripts: scripts))
        try scriptsData.write(to: paths.scriptsJSON)
        append("Scripts: \(scripts.count) — \(scripts.map { $0.name }.joined(separator: ", "))")

        try Task.checkCancellation()

        // STAGE 6: Render
        currentStage = .render
        append("--- Rendering outputs ---")
        let rendered = try await Renderer.shared.render(
            scripts: scripts,
            master: paths.masterMov,
            masterDuration: masterDuration,
            projectRoot: projectRoot,
            progress: { [weak self] line in Task { @MainActor in self?.append(line) } }
        )
        results = rendered
        artifacts = PipelineArtifacts(
            projectRoot: projectRoot,
            masterURL: paths.masterMov,
            masterDuration: masterDuration,
            transcript: transcript,
            scripts: scripts,
            segments: segments,
            renderResults: rendered,
            paths: paths
        )
        append("Done. \(rendered.count) script(s) rendered to \(projectRoot.path)")
    }

    private func buildRetryPrompt(originalPrompt: String, badResponse: String, error: Error) -> String {
        let truncated = String(badResponse.prefix(4000))
        return """
        Your previous response could not be parsed as JSON.

        Parse error: \(error.localizedDescription)

        Strict requirements for THIS reply:
        1. Output exactly ONE fenced code block: ```json … ```
        2. No prose outside the fence. No leading or trailing text.
        3. Use ONLY ASCII punctuation. No curly/smart quotes (“ ” ‘ ’). No full-width punctuation (｛ ｝ ， ：). Every brace, comma, colon, and quote must be the regular ASCII character.
        4. All numbers must be plain JSON numbers like 12.34. No words mixed in (e.g. "1ividade49.32" is INVALID — it must be just "1949.32" or whatever the correct value is).
        5. Schema:
           {
             "scripts": [
               {
                 "name": "kebab-case-name",
                 "theme": "string",
                 "targetDurationSeconds": 30,
                 "clips": [
                   {"sourceStart": 12.34, "sourceEnd": 18.91, "verbatim": "exact words from transcript"}
                 ]
               }
             ]
           }

        Your previous (broken) response, for context only — do NOT repeat its mistakes:
        ---
        \(truncated)
        ---

        Now reply with ONLY the corrected JSON, fenced.

        --- Original task follows ---
        \(originalPrompt)
        """
    }
}
