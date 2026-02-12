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
    case needsThinking
    case readyToImplement
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
            "Backlog"
        case .needsThinking:
            "Needs Thinking"
        case .readyToImplement:
            "Ready to Implement"
        case .inProgress:
            "In Progress"
        case .blocked:
            "Blocked"
        case .review:
            "Review"
        case .done:
            "Done"
        case .skipped:
            "Skipped"
        case .duplicate:
            "Duplicate"
        }
    }
}

enum StubSize: String {
    case quickTweak = "quick_tweak"
    case straightforwardFeature = "straightforward_feature"
    case requiresThinking = "requires_thinking"
    case majorRefactor = "major_refactor"

    var title: String {
        switch self {
        case .quickTweak:
            "Quick Tweak"
        case .straightforwardFeature:
            "Straightforward Feature"
        case .requiresThinking:
            "Requires Thinking"
        case .majorRefactor:
            "Major Refactor"
        }
    }
}

extension StubSize {
    var ticketSize: TicketSize {
        switch self {
        case .quickTweak:
            .quickTweak
        case .straightforwardFeature:
            .straightforwardFeature
        case .requiresThinking:
            .requiresThinking
        case .majorRefactor:
            .majorRefactor
        }
    }
}

extension StubTicketState {
    var ticketQuickStatus: TicketQuickStatus {
        switch self {
        case .backlog:
            .backlog
        case .needsThinking:
            .needsThinking
        case .readyToImplement:
            .readyToImplement
        case .inProgress:
            .inProgress
        case .blocked:
            .blocked
        case .review:
            .review
        case .done:
            .done
        case .skipped:
            .skipped
        case .duplicate:
            .duplicate
        }
    }
}

struct StubTicket: Identifiable, Hashable {
    let id: String
    let title: String
    let state: StubTicketState
    let size: StubSize
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
                size: .requiresThinking,
                assignee: "Kelan",
                latestNote: "Checklist drafted and in stakeholder review."
            ),
            StubTicket(
                id: "2",
                title: "Revise pricing page copy",
                state: .readyToImplement,
                size: .straightforwardFeature,
                assignee: "Avery",
                latestNote: "Requirements are clear and implementation is queued."
            ),
            StubTicket(
                id: "3",
                title: "Fix attribution mismatch",
                state: .blocked,
                size: .majorRefactor,
                assignee: "Maya",
                latestNote: "Blocked by delayed warehouse replay job."
            ),
            StubTicket(
                id: "4",
                title: "New referral CTA",
                state: .needsThinking,
                size: .quickTweak,
                assignee: "Riley",
                latestNote: "Needs product and design exploration before implementation."
            ),
        ]

        return baseTickets.map { ticket in
            StubTicket(
                id: "\(project.id.uuidString)_\(ticket.id)",
                title: ticket.title,
                state: ticket.state,
                size: ticket.size,
                assignee: ticket.assignee,
                latestNote: ticket.latestNote
            )
        }
    }
}
