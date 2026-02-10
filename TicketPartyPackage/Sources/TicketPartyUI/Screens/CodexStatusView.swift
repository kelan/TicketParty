import SwiftUI
import TicketPartyDataStore

struct CodexStatusView: View {
    let projects: [Project]

    @Environment(CodexViewModel.self) private var codexViewModel

    var body: some View {
        List {
            if projects.isEmpty {
                ContentUnavailableView("No Projects", systemImage: "folder")
            } else {
                ForEach(projects, id: \.id) { project in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.name)
                            .font(.headline)

                        HStack(spacing: 8) {
                            Text(statusText(for: project.id))
                                .font(.caption)
                                .foregroundStyle(statusColor(for: project.id))
                            if let workingDirectory = project.workingDirectory, workingDirectory.isEmpty == false {
                                Text(workingDirectory)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("No working directory")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Codex")
    }

    private func statusText(for projectID: UUID) -> String {
        codexViewModel.status(for: projectID).title
    }

    private func statusColor(for projectID: UUID) -> Color {
        switch codexViewModel.status(for: projectID) {
        case .running:
            return .green
        case .starting:
            return .orange
        case .error:
            return .red
        case .stopped:
            return .secondary
        }
    }
}
