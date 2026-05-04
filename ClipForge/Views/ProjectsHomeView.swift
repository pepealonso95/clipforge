import SwiftUI
import AppKit

/// Landing page: list of projects on disk + "+ New project" entry point.
struct ProjectsHomeView: View {
    var onOpen: (ProjectSummary) -> Void
    var onNew: () -> Void

    @State private var projects: [ProjectSummary] = []
    @State private var hoveringNew: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if projects.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onAppear { reload() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ClipForge").font(.largeTitle).bold()
                Text("Pick up where you left off, or start a new project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onNew()
            } label: {
                Label("New project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No projects yet")
                .font(.title3)
            Text("Start a new project to import a video and generate clips.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("New project") { onNew() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(projects) { p in
                    ProjectRow(
                        project: p,
                        onOpen: { onOpen(p) },
                        onReveal: {
                            NSWorkspace.shared.activateFileViewerSelecting([p.path])
                        }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func reload() {
        projects = ProjectStore.listProjects()
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary
    var onOpen: () -> Void
    var onReveal: () -> Void

    @State private var hovered: Bool = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                Image(systemName: project.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(project.isComplete ? Color.accentColor : Color.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 10) {
                        if let n = project.scriptsCount {
                            Label("\(n) script\(n == 1 ? "" : "s")", systemImage: "text.alignleft")
                                .labelStyle(.titleAndIcon)
                        } else if !project.isComplete {
                            Label("Incomplete", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Label(relativeDate(project.lastModified), systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if hovered {
                    Button {
                        onReveal()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(hovered ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!project.isComplete)
        .opacity(project.isComplete ? 1 : 0.7)
        .onHover { hovered = $0 }
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
