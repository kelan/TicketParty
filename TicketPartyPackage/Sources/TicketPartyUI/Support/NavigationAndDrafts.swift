import Foundation
import TicketPartyDataStore

enum SidebarSelection: Hashable {
    case activity
    case allProjects
    case codex
    case project(UUID)
}

struct ProjectDraft: Equatable {
    var name: String = ""
    var statusText: String = ""
    var summary: String = ""
    var workingDirectory: String = ""

    var normalized: ProjectDraft {
        ProjectDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            statusText: statusText.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var normalizedWorkingDirectory: String? {
        let normalized = normalized.workingDirectory
        return normalized.isEmpty ? nil : normalized
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
