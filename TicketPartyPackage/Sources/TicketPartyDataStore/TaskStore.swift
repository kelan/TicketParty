import Foundation
import SwiftData
import TicketPartyModels

public struct TaskSummary: Codable {
    public let id: UUID
    public let displayID: String
    public let title: String
    public let priority: String
    public let severity: String
    public let updatedAt: Date
}

public enum TicketPartyTaskStore {
    public static func listTasks() throws -> [TaskSummary] {
        let context = try makeContext()
        let descriptor = FetchDescriptor<Task>(
            sortBy: [SortDescriptor(\Task.ticketNumber, order: .forward)]
        )
        let tasks = try context.fetch(descriptor)
        return tasks.map(toSummary)
    }

    @discardableResult
    public static func createTask(title: String, description: String = "") throws -> TaskSummary {
        let context = try makeContext()

        var maxTicketDescriptor = FetchDescriptor<Task>(
            sortBy: [SortDescriptor(\Task.ticketNumber, order: .reverse)]
        )
        maxTicketDescriptor.fetchLimit = 1
        let maxTicketNumber = try context.fetch(maxTicketDescriptor).first?.ticketNumber ?? 0
        let nextTicketNumber = maxTicketNumber + 1

        let task = Task(
            ticketNumber: nextTicketNumber,
            displayID: "TT-\(nextTicketNumber)",
            title: title,
            description: description
        )

        context.insert(task)
        try context.save()
        return toSummary(task)
    }

    private static func makeContext() throws -> ModelContext {
        let container = try TicketPartyPersistence.makeSharedContainer()
        return ModelContext(container)
    }

    private static func toSummary(_ task: Task) -> TaskSummary {
        TaskSummary(
            id: task.id,
            displayID: task.displayID,
            title: task.title,
            priority: task.priority.rawValue,
            severity: task.severity.rawValue,
            updatedAt: task.updatedAt
        )
    }
}
