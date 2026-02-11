import Foundation
import TicketPartyDataStore
import TicketPartyModels

struct StubProject: Identifiable, Hashable {
    let id: UUID
    let name: String
    let statusText: String
    let summary: String
}

enum StubTicketState: String, CaseIterable, Identifiable {
    case backlog
    case inProgress
    case blocked
    case review
    case done
    case skipped
    case duplicate

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
        case .skipped:
            return "Skipped"
        case .duplicate:
            return "Duplicate"
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

extension StubPriority {
    var ticketPriority: TicketPriority {
        switch self {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        }
    }

    var ticketSeverity: TicketSeverity {
        switch self {
        case .low:
            return .minor
        case .medium:
            return .major
        case .high:
            return .critical
        }
    }
}

extension StubTicketState {
    var ticketQuickStatus: TicketQuickStatus {
        switch self {
        case .backlog:
            return .backlog
        case .inProgress:
            return .inProgress
        case .blocked:
            return .blocked
        case .review:
            return .review
        case .done:
            return .done
        case .skipped:
            return .skipped
        case .duplicate:
            return .duplicate
        }
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
    static let projects: [StubProject] = [
        StubProject(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
            name: "Growth Site",
            statusText: "Release candidate",
            summary: "Final QA and launch checklist in progress."
        ),
        StubProject(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
            name: "iOS App",
            statusText: "Stabilizing",
            summary: "Crash fixes and polish for the next App Store build."
        ),
        StubProject(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
            name: "Ops Automation",
            statusText: "Healthy",
            summary: "Credential rotation and monitoring updates completed."
        ),
    ]

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
