import Foundation
import TicketPartyDataStore
import TicketPartyModels

struct TicketDraft: Equatable {
    var projectID: UUID?
    var title: String = ""
    var description: String = ""
    var priority: TicketPriority = .medium
    var severity: TicketSeverity = .major

    var normalized: TicketDraft {
        TicketDraft(
            projectID: projectID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            severity: severity
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
        priority: TicketPriority = .medium,
        severity: TicketSeverity = .major
    ) {
        self.projectID = projectID
        self.title = title
        self.description = description
        self.priority = priority
        self.severity = severity
    }

    init(ticket: Ticket) {
        projectID = ticket.projectID
        title = ticket.title
        description = ticket.ticketDescription
        priority = ticket.priority
        severity = ticket.severity
    }
}

extension TicketPriority {
    var title: String {
        rawValue.capitalized
    }
}

extension TicketSeverity {
    var title: String {
        rawValue.capitalized
    }
}

public extension Notification.Name {
    static let ticketPartyNewTicketRequested = Notification.Name("TicketParty.newTicketRequested")
    static let ticketPartyMoveSelectedTicketUpRequested = Notification.Name("TicketParty.moveSelectedTicketUpRequested")
    static let ticketPartyMoveSelectedTicketDownRequested = Notification.Name("TicketParty.moveSelectedTicketDownRequested")
}
