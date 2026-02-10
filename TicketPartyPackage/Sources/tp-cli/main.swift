import Foundation
import TicketPartyModels

private func run(arguments: [String]) throws {
    guard arguments.isEmpty == false else {
        printUsage()
        return
    }

    switch (arguments.first, arguments.dropFirst().first) {
//    case ("ticket", "list"):
//        let json = arguments.contains("--json")
//        let tickets = try TicketPartyTicketStore.listTickets()
//        if json {
//            try printJSON(tickets)
//        } else if tickets.isEmpty {
//            print("No tickets found.")
//        } else {
//            for ticket in tickets {
//                print("\(ticket.displayID)\t\(ticket.title)\t\(ticket.priority)")
//            }
//        }
//    case ("ticket", "create"):
//        let json = arguments.contains("--json")
//        let titleParts = arguments.dropFirst(2).filter { $0 != "--json" }
//        guard titleParts.isEmpty == false else {
//            throw CLIError("Usage: tp ticket create <title> [--json]")
//        }
//
//        let ticket = try TicketPartyTicketStore.createTicket(title: titleParts.joined(separator: " "))
//        if json {
//            try printJSON(ticket)
//        } else {
//            print("Created \(ticket.displayID): \(ticket.title)")
//        }
    default:
        printUsage()
    }
}

private func printUsage() {
    print(
        """
        tp - TicketParty CLI

        Commands:
          tp list [--json]
          tp create <title> [--json]
        """
    )
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
        throw CLIError("Failed to encode JSON output")
    }
    print(output)
}

private struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

do {
    try run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
