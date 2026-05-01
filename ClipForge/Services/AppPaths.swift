import Foundation

enum AppPaths {
    /// `~/Library/Application Support/ClipForge/`
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("ClipForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `~/Library/Application Support/ClipForge/models/`
    static var modelsDir: URL {
        let url = supportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Path to a bundled binary in the app bundle's Resources/Bin directory.
    /// Returns nil if the binary isn't present (e.g. running from SwiftPM without Resources).
    static func bundledBinary(_ name: String) -> URL? {
        // Try app bundle Resources/Bin/<name>
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Bin") {
            return url
        }
        // Fallback: Bundle.main.resourceURL/Bin/<name> for folder-reference layouts
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("Bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func bundledPrompt(_ name: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Prompts") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("Prompts/\(name)")
            return try? String(contentsOf: candidate, encoding: .utf8)
        }
        return nil
    }

    /// URL of a subfolder inside `References/` in the app bundle (e.g. "guidelines", "samples").
    static func bundledReferencesURL(in subfolder: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("References/\(subfolder)", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }
}
