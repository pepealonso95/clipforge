import Foundation

struct ProjectInputs {
    var sourceFiles: [URL]
    var outputDirectory: URL
    var projectName: String
    var userPrompt: String
}

struct ProjectPaths {
    let projectRoot: URL
    let workingDir: URL
    let masterMov: URL
    let segmentsJSON: URL
    let audioWav: URL
    let transcriptJSON: URL
    let scriptsJSON: URL
    let sessionLog: URL
    let aiPrompt: URL
    let aiResponseRaw: URL
    let aiStderr: URL
    let aiPromptRetry: URL
    let aiResponseRawRetry: URL
    let aiStderrRetry: URL

    init(root: URL) {
        projectRoot = root
        workingDir = root.appendingPathComponent("working")
        masterMov = workingDir.appendingPathComponent("master.mov")
        segmentsJSON = workingDir.appendingPathComponent("segments.json")
        audioWav = workingDir.appendingPathComponent("audio.wav")
        transcriptJSON = workingDir.appendingPathComponent("transcript.json")
        scriptsJSON = workingDir.appendingPathComponent("scripts.json")
        sessionLog = workingDir.appendingPathComponent("session.log")
        aiPrompt = workingDir.appendingPathComponent("ai_prompt.txt")
        aiResponseRaw = workingDir.appendingPathComponent("ai_response_raw.txt")
        aiStderr = workingDir.appendingPathComponent("ai_stderr.txt")
        aiPromptRetry = workingDir.appendingPathComponent("ai_prompt_retry.txt")
        aiResponseRawRetry = workingDir.appendingPathComponent("ai_response_raw_retry.txt")
        aiStderrRetry = workingDir.appendingPathComponent("ai_stderr_retry.txt")
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: workingDir, withIntermediateDirectories: true)
    }
}

struct SourceSegment: Codable {
    /// Source file URL (absolute path string for portability of the working dir).
    let sourcePath: String
    /// Start time in master.mov (seconds).
    let startInMaster: Double
    /// End time in master.mov (seconds).
    let endInMaster: Double
    /// Duration of the source file (seconds).
    let duration: Double
}
