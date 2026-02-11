import SwiftUI
import TicketPartyDataStore

struct CodexStatusView: View {
    let projects: [Project]

    @Environment(CodexViewModel.self) private var codexViewModel

    var body: some View {
        List {
            Section("Supervisor") {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(supervisorColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(codexViewModel.supervisorHealth.title)
                            .font(.headline)
                        Text(codexViewModel.supervisorHealth.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Refresh") {
                        Task {
                            await codexViewModel.refreshSupervisorHealth()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }

            Section("Projects") {
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
        }
        .task {
            await codexViewModel.refreshSupervisorHealth()
        }
        .navigationTitle("Agents")
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

    private var supervisorColor: Color {
        switch codexViewModel.supervisorHealth {
        case .healthy:
            .green
        case .notRunning:
            .secondary
        case .staleRecord, .unreachable:
            .orange
        case .handshakeFailed, .invalidRecord:
            .red
        }
    }
}
