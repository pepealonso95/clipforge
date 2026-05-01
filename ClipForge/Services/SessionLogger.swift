import Foundation

/// Per-run log file writer. Mirrors UI log lines to:
///   1. <project>/working/session.log (moves with the project)
///   2. ~/Library/Application Support/ClipForge/logs/<timestamp>__<project>.log (global tail-able)
final class SessionLogger {
    let projectLogURL: URL
    let globalLogURL: URL

    private let formatter: DateFormatter
    private let queue = DispatchQueue(label: "ClipForge.SessionLogger", qos: .utility)

    init(projectPaths: ProjectPaths, projectName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: projectPaths.workingDir, withIntermediateDirectories: true)

        let logsDir = AppPaths.supportDir.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let stamp = SessionLogger.timestampFilename(Date())
        let safeName = projectName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")

        projectLogURL = projectPaths.sessionLog
        globalLogURL = logsDir.appendingPathComponent("\(stamp)__\(safeName).log")

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.current
        formatter = f

        let header = """
        # ClipForge session log
        # Project: \(projectName)
        # Started: \(formatter.string(from: Date()))
        # Project root: \(projectPaths.projectRoot.path)
        # Working dir: \(projectPaths.workingDir.path)

        """
        try header.write(to: projectLogURL, atomically: true, encoding: .utf8)
        try header.write(to: globalLogURL, atomically: true, encoding: .utf8)
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [projectLogURL, globalLogURL] in
            Self.append(data, to: projectLogURL)
            Self.append(data, to: globalLogURL)
        }
    }

    private static func append(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // ignore
            }
        }
    }

    private static func timestampFilename(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
