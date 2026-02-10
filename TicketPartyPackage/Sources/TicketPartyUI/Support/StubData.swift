import Foundation
import TicketPartyDataStore

enum StubTicketState: String, CaseIterable, Identifiable {
    case backlog
    case inProgress
    case blocked
    case review
    case done

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .backlog:
            return "Backlog"
        case .inProgress:
            return "In Progress"
        case .blocked:
            return "Blocked"
        case .review:
            return "Review"
        case .done:
            return "Done"
        }
    }
}

enum StubPriority: String {
    case low
    case medium
    case high

    var title: String {
        rawValue.capitalized
    }
}

struct StubTicket: Identifiable, Hashable {
    let id: String
    let title: String
    let state: StubTicketState
    let priority: StubPriority
    let assignee: String
    let latestNote: String
}

struct StubActivityEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let timestamp: String
}

enum SampleData {
    static let activityEvents: [StubActivityEvent] = [
        StubActivityEvent(
            id: "activity_1",
            title: "Growth Site moved to Review",
            subtitle: "Plan release checklist is waiting for sign-off",
            timestamp: "Today 9:42 AM"
        ),
        StubActivityEvent(
            id: "activity_2",
            title: "iOS App crash fix completed",
            subtitle: "Settings crash patch marked Done",
            timestamp: "Today 8:17 AM"
        ),
        StubActivityEvent(
            id: "activity_3",
            title: "Ops Automation credential rotation finished",
            subtitle: "Production secrets rotated and validated",
            timestamp: "Yesterday 5:05 PM"
        ),
    ]

    static func tickets(for project: Project) -> [StubTicket] {
        let baseTickets: [StubTicket] = [
            StubTicket(
                id: "1",
                title: "Plan release checklist",
                state: .review,
                priority: .high,
                assignee: "Kelan",
                latestNote: "Checklist drafted and in stakeholder review."
            ),
            StubTicket(
                id: "2",
                title: "Revise pricing page copy",
                state: .inProgress,
                priority: .medium,
                assignee: "Avery",
                latestNote: "Legal language updates still pending."
            ),
            StubTicket(
                id: "3",
                title: "Fix attribution mismatch",
                state: .blocked,
                priority: .high,
                assignee: "Maya",
                latestNote: "Blocked by delayed warehouse replay job."
            ),
            StubTicket(
                id: "4",
                title: "New referral CTA",
                state: .backlog,
                priority: .low,
                assignee: "Riley",
                latestNote: "Pending design exploration."
            ),
        ]

        return baseTickets.map { ticket in
            StubTicket(
                id: "\(project.id.uuidString)_\(ticket.id)",
                title: ticket.title,
                state: ticket.state,
                priority: ticket.priority,
                assignee: ticket.assignee,
                latestNote: ticket.latestNote
            )
        }
    }
}
