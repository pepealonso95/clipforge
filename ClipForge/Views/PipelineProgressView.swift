import SwiftUI

/// Replaces the old log-heavy right pane with a centered, friendly progress
/// screen. The technical log is preserved verbatim behind a "Show details"
/// disclosure for power users / debugging.
struct PipelineProgressView: View {
    @ObservedObject var pipeline: Pipeline
    var onCancel: () -> Void
    var onBackToSetup: () -> Void

    @State private var showDetails: Bool = false

    private var hasError: Bool { pipeline.error != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .center, spacing: 24) {
                stepper
                statusBlock
                detailsDisclosure
                footer
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 32)
        .onAppear {
            // If we landed here already in error, show details by default.
            if hasError { showDetails = true }
        }
        .onChange(of: hasError) { _, isErr in
            if isErr { showDetails = true }
        }
    }

    // MARK: - Sections

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Array(PipelineStage.allCases.enumerated()), id: \.element) { idx, stage in
                StepDot(state: state(for: stage))
                if idx < PipelineStage.allCases.count - 1 {
                    Rectangle()
                        .fill(connectorColor(after: stage))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statusBlock: some View {
        VStack(spacing: 10) {
            if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.red)
                Text("Something went wrong")
                    .font(.title2).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                if let err = pipeline.error {
                    Text(err.localizedDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 4)
                Text(pipeline.currentStage?.friendlyTitle ?? "Getting started…")
                    .font(.title2).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                Text(pipeline.currentStage?.friendlySubtitle ?? "Preparing the pipeline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            LogView(lines: pipeline.log)
                .frame(height: 220)
                .padding(.top, 8)
        } label: {
            Text("Show details")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if hasError {
                Button("Back to setup") { onBackToSetup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Cancel") { onCancel() }
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Stepper helpers

    private func state(for stage: PipelineStage) -> StepDot.State {
        guard let current = pipeline.currentStage else {
            return hasError ? .upcoming : .upcoming
        }
        if hasError && stage == current { return .error }
        if stage.stepIndex < current.stepIndex { return .done }
        if stage == current { return .current }
        return .upcoming
    }

    private func connectorColor(after stage: PipelineStage) -> Color {
        guard let current = pipeline.currentStage else { return Color.secondary.opacity(0.25) }
        return stage.stepIndex < current.stepIndex
            ? Color.accentColor.opacity(0.6)
            : Color.secondary.opacity(0.25)
    }
}

// MARK: - StepDot

private struct StepDot: View {
    enum State { case done, current, upcoming, error }
    let state: State

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 22, height: 22)
            Circle()
                .stroke(stroke, lineWidth: 1.5)
                .frame(width: 22, height: 22)
            if state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else if state == .error {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else if state == .current {
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch state {
        case .done:     return Color.accentColor
        case .current:  return Color.accentColor
        case .upcoming: return Color.clear
        case .error:    return Color.red
        }
    }

    private var stroke: Color {
        switch state {
        case .done, .current: return Color.accentColor
        case .upcoming:        return Color.secondary.opacity(0.4)
        case .error:           return Color.red
        }
    }
}

// MARK: - LogView

/// Auto-scrolling, monospaced log viewer. ERROR lines render in red.
private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.contains("ERROR") ? .red : .primary)
                            .id(idx)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _, _ in
                if let last = lines.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}
