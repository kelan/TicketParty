import SwiftUI
import TicketPartyDataStore

struct OverallKanbanView: View {
    let projects: [Project]
    private let states = StubTicketState.allCases

    private func tickets(for project: Project) -> [StubTicket] {
        PreviewRuntime.usesStubData ? SampleData.tickets(for: project) : []
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Project")
                        .font(.caption.weight(.semibold))
                        .frame(width: 180, alignment: .leading)

                    ForEach(states) { state in
                        Text(state.title)
                            .font(.caption.weight(.semibold))
                            .frame(width: 210, alignment: .leading)
                    }
                }

                ForEach(projects, id: \.id) { project in
                    let tickets = tickets(for: project)

                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.headline)
                            Text(project.sidebarSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 180, alignment: .leading)

                        ForEach(states) { state in
                            KanbanCell(tickets: tickets.filter { $0.state == state })
                                .frame(width: 210, alignment: .leading)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("All Projects")
    }
}

private struct KanbanCell: View {
    let tickets: [StubTicket]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(tickets.count) ticket\(tickets.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if tickets.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tickets.prefix(2)) { ticket in
                    Text(ticket.title)
                        .font(.caption)
                        .lineLimit(1)
                }

                if tickets.count > 2 {
                    Text("+\(tickets.count - 2) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
