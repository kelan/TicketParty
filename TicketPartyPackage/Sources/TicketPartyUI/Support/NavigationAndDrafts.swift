import Foundation
import TicketPartyDataStore

enum SidebarSelection: Hashable {
    case activity
    case allProjects
    case project(UUID)
}

struct ProjectDraft: Equatable {
    var name: String = ""
    var statusText: String = ""
    var summary: String = ""

    var normalized: ProjectDraft {
        ProjectDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            statusText: statusText.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension Project {
    var sidebarSubtitle: String {
        if statusText.isEmpty == false {
            return statusText
        }

        if summary.isEmpty == false {
            return summary
        }

        return "No status yet"
    }
}
