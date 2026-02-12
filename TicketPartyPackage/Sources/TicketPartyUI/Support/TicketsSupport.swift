import Foundation
import TicketPartyDataStore
import TicketPartyModels

enum TicketQuickStatus: String, CaseIterable, Identifiable {
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

    var stateID: UUID {
        switch self {
        case .backlog:
            Self.statusBacklogID
        case .needsThinking:
            Self.statusNeedsThinkingID
        case .readyToImplement:
            Self.statusReadyToImplementID
        case .inProgress:
            Self.statusInProgressID
        case .blocked:
            Self.statusBlockedID
        case .review:
            Self.statusReviewID
        case .done:
            Self.statusDoneID
        case .skipped:
            Self.statusSkippedID
        case .duplicate:
            Self.statusDuplicateID
        }
    }

    var isDone: Bool {
        switch self {
        case .done, .skipped, .duplicate:
            true
        case .inProgress, .review, .backlog, .blocked, .needsThinking, .readyToImplement:
            false
        }
    }

    init(stateID: UUID?) {
        guard let stateID else {
            self = .backlog
            return
        }

        self = Self.allCases.first(where: { $0.stateID == stateID }) ?? .backlog
    }

    private static let statusBacklogID = Self.makeID("6D9887A9-A3BA-4F77-9C97-6BC9AFA17C1D")
    private static let statusNeedsThinkingID = Self.makeID("990C756C-2492-435F-A75D-7CFECC34C324")
    private static let statusReadyToImplementID = Self.makeID("BD2638C9-DF9B-488F-ADF8-656B42B12D3D")
    private static let statusInProgressID = Self.makeID("B47B66F8-A6A8-4C1E-B8F7-D8DDE826D212")
    private static let statusBlockedID = Self.makeID("AA91174D-EAD8-41F6-AD2C-E6D950D8B5E3")
    private static let statusReviewID = Self.makeID("A81DC87E-B2FA-4A02-9783-B3AA647A36B4")
    private static let statusDoneID = Self.makeID("F9C0E777-D8EA-4542-8C3E-7BC2CF0A5CF5")
    private static let statusSkippedID = Self.makeID("BAD4A862-631E-4A1A-AFCB-F1A2C33B7607")
    private static let statusDuplicateID = Self.makeID("4EB8D67D-2A65-463D-9356-38AB280192B1")

    private static func makeID(_ value: String) -> UUID {
        guard let id = UUID(uuidString: value) else {
            preconditionFailure("Invalid status UUID: \(value)")
        }
        return id
    }
}

extension Ticket {
    var quickStatus: TicketQuickStatus {
        get { TicketQuickStatus(stateID: stateID) }
        set {
            let wasDone = TicketQuickStatus(stateID: stateID).isDone
            stateID = newValue.stateID

            if newValue.isDone {
                if wasDone == false || doneAt == nil {
                    doneAt = .now
                }
            } else {
                doneAt = nil
            }
        }
    }
}

struct TicketDraft: Equatable {
    var projectID: UUID?
    var title: String = ""
    var description: String = ""
    var size: TicketSize = .straightforwardFeature
    var addToTopOfBacklog = false

    var normalized: TicketDraft {
        TicketDraft(
            projectID: projectID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            size: size,
            addToTopOfBacklog: addToTopOfBacklog
        )
    }

    var canSubmit: Bool {
        let normalized = normalized
        return normalized.projectID != nil && normalized.title.isEmpty == false
    }

    init(
        projectID: UUID? = nil,
        title: String = "",
        description: String = "",
        size: TicketSize = .straightforwardFeature,
        addToTopOfBacklog: Bool = false
    ) {
        self.projectID = projectID
        self.title = title
        self.description = description
        self.size = size
        self.addToTopOfBacklog = addToTopOfBacklog
    }

    init(ticket: Ticket) {
        projectID = ticket.projectID
        title = ticket.title
        description = ticket.ticketDescription
        size = ticket.size
        addToTopOfBacklog = false
    }
}

extension TicketSize {
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

public extension Notification.Name {
    static let ticketPartyNewTicketRequested = Notification.Name("TicketParty.newTicketRequested")
    static let ticketPartyEditSelectedTicketRequested = Notification.Name("TicketParty.editSelectedTicketRequested")
    static let ticketPartyToggleAddToTopOfBacklogRequested = Notification.Name("TicketParty.toggleAddToTopOfBacklogRequested")
    static let ticketPartyMoveSelectedTicketToTopRequested = Notification.Name("TicketParty.moveSelectedTicketToTopRequested")
    static let ticketPartyMoveSelectedTicketUpRequested = Notification.Name("TicketParty.moveSelectedTicketUpRequested")
    static let ticketPartyMoveSelectedTicketDownRequested = Notification.Name("TicketParty.moveSelectedTicketDownRequested")
}
