import Foundation
import SwiftUI

enum WhisperMode: String, CaseIterable, Codable {
    case local
    case openAI

    var displayName: String {
        switch self {
        case .local: return "Local (whisper.cpp)"
        case .openAI: return "OpenAI API"
        }
    }
}

enum AICliKind: String, CaseIterable, Codable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

enum WhisperModel: String, CaseIterable, Codable {
    case tiny = "ggml-tiny.en.bin"
    case base = "ggml-base.en.bin"
    case small = "ggml-small.en.bin"
    case medium = "ggml-medium.en.bin"
    case large = "ggml-large-v3.bin"

    var displayName: String {
        switch self {
        case .tiny: return "tiny.en (75 MB)"
        case .base: return "base.en (140 MB)"
        case .small: return "small.en (470 MB)"
        case .medium: return "medium.en (1.5 GB)"
        case .large: return "large-v3 (2.9 GB)"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var whisperMode: WhisperMode {
        didSet { UserDefaults.standard.set(whisperMode.rawValue, forKey: "whisperMode") }
    }
    @Published var aiCli: AICliKind {
        didSet { UserDefaults.standard.set(aiCli.rawValue, forKey: "aiCli") }
    }
    @Published var openaiAPIKey: String {
        didSet { UserDefaults.standard.set(openaiAPIKey, forKey: "openaiAPIKey") }
    }
    @Published var yoloMode: Bool {
        didSet { UserDefaults.standard.set(yoloMode, forKey: "yoloMode") }
    }
    @Published var whisperModel: WhisperModel {
        didSet { UserDefaults.standard.set(whisperModel.rawValue, forKey: "whisperModel") }
    }
    @Published var keepWorkingFiles: Bool {
        didSet { UserDefaults.standard.set(keepWorkingFiles, forKey: "keepWorkingFiles") }
    }

    init() {
        let d = UserDefaults.standard
        whisperMode = WhisperMode(rawValue: d.string(forKey: "whisperMode") ?? "") ?? .local
        aiCli = AICliKind(rawValue: d.string(forKey: "aiCli") ?? "") ?? .claude
        openaiAPIKey = d.string(forKey: "openaiAPIKey") ?? ""
        yoloMode = d.bool(forKey: "yoloMode")
        whisperModel = WhisperModel(rawValue: d.string(forKey: "whisperModel") ?? "") ?? .base
        if d.object(forKey: "keepWorkingFiles") == nil {
            keepWorkingFiles = true
        } else {
            keepWorkingFiles = d.bool(forKey: "keepWorkingFiles")
        }
    }

    /// In YOLO mode, swap to the *other* CLI per the project plan.
    var effectiveAICli: AICliKind {
        yoloMode ? (aiCli == .claude ? .codex : .claude) : aiCli
    }
}
