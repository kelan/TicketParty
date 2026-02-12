import SwiftData
import SwiftUI
import TicketPartyDataStore

struct CodexStatusView: View {
    @Query(sort: [SortDescriptor(\Ticket.orderKey, order: .forward), SortDescriptor(\Ticket.createdAt, order: .forward)]) private var allTickets: [Ticket]
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
                                Text(loopStateText(for: project.id))
                                    .font(.caption)
                                    .foregroundStyle(loopStateColor(for: project.id))
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

                            HStack(spacing: 8) {
                                ForEach(loopButtons(for: project), id: \.title) { item in
                                    Button(item.title) {
                                        Task {
                                            await item.action()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(item.isDisabled)
                                }
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
        .navigationTitle("Agents")
    }

    private func statusText(for projectID: UUID) -> String {
        codexViewModel.status(for: projectID).title
    }

    private func statusColor(for projectID: UUID) -> Color {
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

    private struct LoopButton {
        let title: String
        let isDisabled: Bool
        let action: () async -> Void
    }

    private func loopButtons(for project: Project) -> [LoopButton] {
        switch codexViewModel.loopState(for: project.id) {
        case .idle, .completed:
            [
                LoopButton(
                    title: "Run Loop",
                    isDisabled: false,
                    action: { [allTickets, project] in
                        await codexViewModel.startLoop(project: project, tickets: allTickets)
                    }
                ),
            ]

        case .preparingQueue, .running:
            [
                LoopButton(
                    title: "Pause",
                    isDisabled: false,
                    action: { [projectID = project.id] in
                        await codexViewModel.pauseLoop(projectID: projectID)
                    }
                ),
                LoopButton(
                    title: "Cancel",
                    isDisabled: false,
                    action: { [projectID = project.id] in
                        await codexViewModel.cancelLoop(projectID: projectID)
                    }
                ),
            ]

        case .paused, .failed:
            [
                LoopButton(
                    title: "Resume",
                    isDisabled: false,
                    action: { [allTickets, project] in
                        await codexViewModel.resumeLoop(project: project, tickets: allTickets)
                    }
                ),
                LoopButton(
                    title: "Cancel",
                    isDisabled: false,
                    action: { [projectID = project.id] in
                        await codexViewModel.cancelLoop(projectID: projectID)
                    }
                ),
            ]

        case .cancelling:
            [
                LoopButton(
                    title: "Cancelling…",
                    isDisabled: true,
                    action: {}
                ),
            ]
        }
    }
}
