import SwiftUI

private enum Screen {
    case home
    case setup
    case editor
}

/// Top-level state router: home → (setup → progress) → editor.
/// Owns the long-lived `Pipeline` so its observable state persists across
/// transitions between progress and editor.
struct ProjectView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var pipeline = Pipeline()

    @State private var screen: Screen = .home
    @State private var didAutoOpen: Bool = false

    var body: some View {
        Group {
            // Pipeline runtime states always take priority over `screen`.
            if pipeline.isRunning || pipeline.error != nil {
                PipelineProgressView(
                    pipeline: pipeline,
                    onCancel: { pipeline.cancel() },
                    onBackToSetup: {
                        pipeline.reset()
                        screen = .setup
                    }
                )
            } else if pipeline.artifacts != nil {
                editor
            } else {
                switch screen {
                case .home:   home
                case .setup:  setup
                case .editor: home // stale fallback — artifacts gate handled above
                }
            }
        }
        .onAppear { autoOpenLastIfPossible() }
    }

    // MARK: - Screens

    private var home: some View {
        ProjectsHomeView(
            onOpen: { summary in
                guard let artifacts = ProjectStore.loadArtifacts(at: summary.path) else {
                    // Loading failed — fall back to setup so the user isn't stuck.
                    screen = .setup
                    return
                }
                pipeline.artifacts = artifacts
                pipeline.results = artifacts.renderResults
                ProjectStore.lastOpenedProjectPath = summary.path
            },
            onNew: { screen = .setup }
        )
    }

    private var setup: some View {
        SetupView(
            onGenerate: { inputs in
                pipeline.run(inputs: inputs, settings: settings)
            },
            onBack: { screen = .home }
        )
    }

    private var editor: some View {
        EditorView(
            artifacts: Binding(
                get: { pipeline.artifacts ?? placeholderArtifacts() },
                set: { pipeline.artifacts = $0 }
            ),
            onBack: {
                if let root = pipeline.artifacts?.projectRoot {
                    ProjectStore.lastOpenedProjectPath = root
                }
                pipeline.artifacts = nil
                pipeline.results = []
                screen = .home
            }
        )
        .onAppear {
            // Remember whatever just landed in the editor (fresh run or reload).
            if let root = pipeline.artifacts?.projectRoot {
                ProjectStore.lastOpenedProjectPath = root
            }
        }
    }

    // MARK: - Helpers

    private func autoOpenLastIfPossible() {
        guard !didAutoOpen else { return }
        didAutoOpen = true
        guard pipeline.artifacts == nil, !pipeline.isRunning,
              let lastPath = ProjectStore.lastOpenedProjectPath,
              let artifacts = ProjectStore.loadArtifacts(at: lastPath)
        else { return }
        pipeline.artifacts = artifacts
        pipeline.results = artifacts.renderResults
    }

    /// Unreachable placeholder — the editor branch is gated on artifacts != nil,
    /// but Binding<T> needs a non-optional getter.
    private func placeholderArtifacts() -> PipelineArtifacts {
        let dummy = ProjectPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        return PipelineArtifacts(
            projectRoot: dummy.projectRoot,
            masterURL: dummy.masterMov,
            masterDuration: 0,
            transcript: Transcript(language: nil, duration: 0, segments: [], words: nil),
            scripts: [],
            segments: [],
            renderResults: [],
            paths: dummy
        )
    }
}
