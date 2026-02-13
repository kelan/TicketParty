import Foundation
import TicketPartyDataStore

enum ProjectListOrdering {
    static func sorted(_ projects: [Project]) -> [Project] {
        projects.sorted(by: isOrderedBefore)
    }

    static func isOrderedBefore(_ lhs: Project, _ rhs: Project) -> Bool {
        if lhs.isArchived != rhs.isArchived {
            return lhs.isArchived == false
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}
