import SwiftUI
import TicketPartyDataStore

struct ActivityView: View {
    let projects: [Project]
    let tickets: [Ticket]

    @Environment(CodexViewModel.self) private var codexViewModel

    private var ticketByID: [UUID: Ticket] {
        Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
    }

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
                                Text(agentStatusText(for: project.id))
                                    .font(.caption)
                                    .foregroundStyle(agentStatusColor(for: project.id))

                                Text(loopStateText(for: project.id))
                                    .font(.caption)
                                    .foregroundStyle(loopStateColor(for: project.id))
                            }

                            if let currentTaskText = currentTaskText(for: project.id) {
                                Text(currentTaskText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            if let loopMessage = codexViewModel.loopMessages[project.id], loopMessage.isEmpty == false {
                                Text(loopMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
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
        .navigationTitle("Activity")
    }

    private func agentStatusText(for projectID: UUID) -> String {
        switch codexViewModel.status(for: projectID) {
        case .running:
            "Agent running"
        case .starting:
            "Agent starting"
        case .stopped:
            "Agent stopped"
        case .error:
            "Agent error"
        }
    }

    private func agentStatusColor(for projectID: UUID) -> Color {
        switch codexViewModel.status(for: projectID) {
        case .running:
            .green
        case .starting:
            .orange
        case .error:
            .red
        case .stopped:
            .secondary
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

    private func loopStateText(for projectID: UUID) -> String {
        switch codexViewModel.loopState(for: projectID) {
        case .idle:
            "Loop idle"
        case .preparingQueue:
            "Loop preparing"
        case let .running(progress):
            "Loop running \(progress.index)/\(progress.total)"
        case let .paused(_, progress):
            "Loop paused at \(progress.index)/\(progress.total)"
        case let .failed(failure, _):
            "Loop failed (\(failure.phase))"
        case let .completed(summary):
            summary.cancelled ? "Loop cancelled" : "Loop completed"
        case .cancelling:
            "Loop cancelling"
        }
    }

    private func loopStateColor(for projectID: UUID) -> Color {
        switch codexViewModel.loopState(for: projectID) {
        case .idle, .completed:
            .secondary
        case .preparingQueue, .running:
            .blue
        case .paused:
            .orange
        case .failed:
            .red
        case .cancelling:
            .orange
        }
    }

    private func currentTaskText(for projectID: UUID) -> String? {
        guard let ticketID = activeTicketID(for: projectID) else { return nil }

        if let ticket = ticketByID[ticketID] {
            return "Current task: \(ticket.displayID) \(ticket.title)"
        }

        return "Current task: \(ticketID.uuidString)"
    }

    private func activeTicketID(for projectID: UUID) -> UUID? {
        let loopState = codexViewModel.loopState(for: projectID)

        switch loopState {
        case let .running(progress):
            return progress.currentTicketID
        case let .paused(_, progress):
            return progress.currentTicketID
        case let .failed(_, progress):
            return progress.currentTicketID
        case let .cancelling(progress):
            return progress.currentTicketID
        case .idle, .preparingQueue, .completed:
            return nil
        }
    }
}
