import Foundation
import TicketPartyShared

private func run(arguments: [String]) throws {
    guard arguments.isEmpty == false else {
        printUsage()
        return
    }

    switch (arguments.first, arguments.dropFirst().first) {
    case ("task", "list"):
        let json = arguments.contains("--json")
        let tasks = try TicketPartyTaskStore.listTasks()
        if json {
            try printJSON(tasks)
        } else if tasks.isEmpty {
            print("No tasks found.")
        } else {
            for task in tasks {
                print("\(task.displayID)\t\(task.title)\t\(task.priority)")
            }
        }
    case ("task", "create"):
        let json = arguments.contains("--json")
        let titleParts = arguments.dropFirst(2).filter { $0 != "--json" }
        guard titleParts.isEmpty == false else {
            throw CLIError("Usage: tp task create <title> [--json]")
        }

        let task = try TicketPartyTaskStore.createTask(title: titleParts.joined(separator: " "))
        if json {
            try printJSON(task)
        } else {
            print("Created \(task.displayID): \(task.title)")
        }
    default:
        printUsage()
    }
}

private func printUsage() {
    print(
        """
        tp - TicketParty CLI

        Commands:
          tp task list [--json]
          tp task create <title> [--json]
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
