import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var modelDownloadProgress: Double = 0
    @State private var modelDownloading: Bool = false
    @State private var modelDownloadError: String? = nil

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            whisperTab
                .tabItem { Label("Whisper", systemImage: "waveform") }
            aiTab
                .tabItem { Label("AI CLI", systemImage: "terminal") }
        }
        .frame(width: 520, height: 360)
    }

    private var generalTab: some View {
        Form {
            Toggle("Keep working files (master.mov, transcript.json) for re-runs", isOn: $settings.keepWorkingFiles)
            Toggle("YOLO mode (use the OTHER AI CLI with permissions skipped)", isOn: $settings.yoloMode)
            HStack {
                Text("Bundled binaries:")
                Spacer()
                Text(bundledBinariesStatus())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var whisperTab: some View {
        Form {
            Picker("Mode", selection: $settings.whisperMode) {
                ForEach(WhisperMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if settings.whisperMode == .openAI {
                SecureField("OpenAI API key (sk-…)", text: $settings.openaiAPIKey)
            } else {
                Picker("Model", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }

                let svc = WhisperLocalService(modelName: settings.whisperModel.rawValue)
                if svc.isModelPresent {
                    Label("Model installed at \(svc.modelURL.path)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Button(modelDownloading ? "Downloading…" : "Download model") {
                            downloadModel()
                        }
                        .disabled(modelDownloading)
                        if modelDownloading {
                            ProgressView(value: modelDownloadProgress).frame(width: 120)
                        }
                    }
                    if let err = modelDownloadError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding()
    }

    private var aiTab: some View {
        Form {
            Picker("Primary CLI", selection: $settings.aiCli) {
                ForEach(AICliKind.allCases, id: \.self) { k in
                    Text(k.displayName).tag(k)
                }
            }

            HStack {
                Text("claude:")
                Spacer()
                Text(BinaryRunner.shared.resolve("claude")?.path ?? "not found on PATH")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("codex:")
                Spacer()
                Text(BinaryRunner.shared.resolve("codex")?.path ?? "not found on PATH")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if settings.yoloMode {
                Text("YOLO is on — runs will use \(settings.effectiveAICli.displayName) with skip-permissions / full-auto.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
    }

    private func bundledBinariesStatus() -> String {
        ["ffmpeg", "ffprobe", "whisper-cli"].map { name in
            "\(name): \(AppPaths.bundledBinary(name) != nil ? "✓" : "✗")"
        }.joined(separator: "  ")
    }

    private func downloadModel() {
        let svc = WhisperLocalService(modelName: settings.whisperModel.rawValue)
        modelDownloading = true
        modelDownloadError = nil
        modelDownloadProgress = 0
        Task {
            do {
                try await svc.downloadModelIfNeeded { frac in
                    Task { @MainActor in
                        modelDownloadProgress = frac
                    }
                }
                await MainActor.run {
                    modelDownloading = false
                    modelDownloadProgress = 1
                }
            } catch {
                await MainActor.run {
                    modelDownloading = false
                    modelDownloadError = error.localizedDescription
                }
            }
        }
    }
}
