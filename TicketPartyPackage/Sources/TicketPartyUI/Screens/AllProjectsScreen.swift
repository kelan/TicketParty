import SwiftData
import SwiftUI
import TicketPartyDataStore
import TicketPartyModels

struct OverallKanbanView: View {
    let projects: [Project]
    private let sizes = TicketSize.allCases

    @Query(sort: [SortDescriptor(\Ticket.orderKey, order: .forward), SortDescriptor(\Ticket.createdAt, order: .forward)]) private var tickets: [Ticket]

    private func tickets(for project: Project, size: TicketSize) -> [Ticket] {
        tickets.filter { ticket in
            ticket.archivedAt == nil &&
                ticket.closedAt == nil &&
                ticket.projectID == project.id &&
                ticket.size == size
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Project")
                        .font(.caption.weight(.semibold))
                        .frame(width: 180, alignment: .leading)

                    ForEach(sizes, id: \.self) { size in
                        Text(size.title)
                            .font(.caption.weight(.semibold))
                            .frame(width: 220, alignment: .leading)
                    }
                }

                ForEach(projects, id: \.id) { project in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.headline)
                            Text(project.sidebarSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 180, alignment: .leading)

                        ForEach(sizes, id: \.self) { size in
                            TicketKanbanCell(tickets: tickets(for: project, size: size))
                                .frame(width: 220, alignment: .leading)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("All Projects")
    }
}

private struct TicketKanbanCell: View {
    let tickets: [Ticket]

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
                ForEach(tickets.prefix(2), id: \.id) { ticket in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.displayID)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(ticket.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
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
