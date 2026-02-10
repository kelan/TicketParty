import Foundation
import SwiftData
import TicketPartyModels

public enum TicketPartyTicketStore {
    public static func listTickets() throws -> [TicketSummary] {
        let context = try makeContext()
        let descriptor = FetchDescriptor<Ticket>(
            sortBy: [SortDescriptor(\Ticket.ticketNumber, order: .forward)]
        )
        let tickets = try context.fetch(descriptor)
        return tickets.map(toSummary)
    }

    @discardableResult
    public static func createTicket(title: String, description: String = "") throws -> TicketSummary {
        let context = try makeContext()

        var maxTicketDescriptor = FetchDescriptor<Ticket>(
            sortBy: [SortDescriptor(\Ticket.ticketNumber, order: .reverse)]
        )
        maxTicketDescriptor.fetchLimit = 1
        let maxTicketNumber = try context.fetch(maxTicketDescriptor).first?.ticketNumber ?? 0
        let nextTicketNumber = maxTicketNumber + 1

        let ticket = Ticket(
            ticketNumber: nextTicketNumber,
            displayID: "TT-\(nextTicketNumber)",
            orderKey: Int64(nextTicketNumber) * 1024,
            title: title,
            description: description
        )

        context.insert(ticket)
        try context.save()
        return toSummary(ticket)
    }

    private static func makeContext() throws -> ModelContext {
        let container = try TicketPartyPersistence.makeSharedContainer()
        return ModelContext(container)
    }

    private static func toSummary(_ ticket: Ticket) -> TicketSummary {
        TicketSummary(
            id: ticket.id,
            displayID: ticket.displayID,
            title: ticket.title,
            priority: ticket.priority.rawValue,
            severity: ticket.severity.rawValue,
            updatedAt: ticket.updatedAt
        )
    }
}
