import Foundation
import SwiftData
import TicketPartyDataStore

enum TicketOrdering {
    static let keyStep: Int64 = 1_024

    static func nextSeedOrderKey(
        context: ModelContext,
        projectID: UUID,
        stateID: UUID? = nil
    ) throws -> Int64 {
        let scopeStateIDs = stateID.map { Set([$0]) }
        let tickets = try fetchActiveScope(context: context, projectID: projectID, scopeStateIDs: scopeStateIDs)
        let maxKey = tickets.map(\.orderKey).max() ?? 0
        return max(maxKey + keyStep, keyStep)
    }

    static func moveTicket(
        context: ModelContext,
        ticketID: UUID,
        projectID: UUID,
        scopeStateIDs: Set<UUID>? = nil,
        beforeTicketID: UUID?,
        afterTicketID: UUID?
    ) throws {
        guard let movedTicket = try fetchTicket(context: context, ticketID: ticketID) else {
            return
        }
        guard movedTicket.closedAt == nil, movedTicket.archivedAt == nil else {
            return
        }

        movedTicket.projectID = projectID

        var scopeTickets = try fetchActiveScope(context: context, projectID: projectID, scopeStateIDs: scopeStateIDs)
        if scopeTickets.contains(where: { $0.id == ticketID }) == false {
            if let scopeStateIDs {
                let movedStateID = movedTicket.stateID ?? TicketQuickStatus.backlog.stateID
                guard scopeStateIDs.contains(movedStateID) else {
                    return
                }
            }
            scopeTickets.append(movedTicket)
            scopeTickets.sort(by: sortByOrderKeyAndCreatedAt)
        }

        func key(for id: UUID?) -> Int64? {
            guard let id else { return nil }
            return scopeTickets.first(where: { $0.id == id })?.orderKey
        }

        var beforeKey = key(for: beforeTicketID)
        var afterKey = key(for: afterTicketID)
        var newKey = midpoint(before: beforeKey, after: afterKey)

        if newKey == nil {
            rebalance(scope: scopeTickets)
            beforeKey = key(for: beforeTicketID)
            afterKey = key(for: afterTicketID)
            newKey = midpoint(before: beforeKey, after: afterKey)
        }

        movedTicket.orderKey = newKey ?? max((beforeKey ?? 0) + keyStep, keyStep)
        movedTicket.updatedAt = .now
        try context.save()
    }

    private static func fetchActiveScope(
        context: ModelContext,
        projectID: UUID,
        scopeStateIDs: Set<UUID>?
    ) throws -> [Ticket] {
        let predicate = #Predicate<Ticket> { ticket in
            ticket.projectID == projectID &&
                ticket.closedAt == nil &&
                ticket.archivedAt == nil
        }
        let descriptor = FetchDescriptor<Ticket>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Ticket.orderKey, order: .forward), SortDescriptor(\Ticket.createdAt, order: .forward)]
        )
        let activeProjectTickets = try context.fetch(descriptor)
        guard let scopeStateIDs else {
            return activeProjectTickets
        }
        return activeProjectTickets.filter { ticket in
            scopeStateIDs.contains(ticket.stateID ?? TicketQuickStatus.backlog.stateID)
        }
    }

    private static func fetchTicket(context: ModelContext, ticketID: UUID) throws -> Ticket? {
        let descriptor = FetchDescriptor<Ticket>(
            predicate: #Predicate<Ticket> { ticket in
                ticket.id == ticketID
            }
        )
        return try context.fetch(descriptor).first
    }

    private static func midpoint(before: Int64?, after: Int64?) -> Int64? {
        switch (before, after) {
        case let (before?, after?):
            guard after > before else { return nil }
            let gap = after - before
            guard gap > 1 else { return nil }
            return before + (gap / 2)

        case let (before?, nil):
            guard before <= (Int64.max - keyStep) else { return nil }
            return before + keyStep

        case let (nil, after?):
            guard after >= (Int64.min + keyStep) else { return nil }
            return after - keyStep

        case (nil, nil):
            return keyStep
        }
    }

    private static func rebalance(scope tickets: [Ticket]) {
        var key = keyStep
        for ticket in tickets.sorted(by: sortByOrderKeyAndCreatedAt) {
            ticket.orderKey = key
            key += keyStep
        }
    }

    private static func sortByOrderKeyAndCreatedAt(_ lhs: Ticket, _ rhs: Ticket) -> Bool {
        if lhs.orderKey == rhs.orderKey {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.orderKey < rhs.orderKey
    }
}
