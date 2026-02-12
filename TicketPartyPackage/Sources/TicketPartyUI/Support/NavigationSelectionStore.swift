import Foundation

struct NavigationSelectionStore {
    private struct PersistedState: Codable {
        var sidebarSelection: PersistedSidebarSelection?
        var selectedTicketIDsByProjectID: [String: String]

        static let empty = PersistedState(
            sidebarSelection: nil,
            selectedTicketIDsByProjectID: [:]
        )
    }

    private enum PersistedSidebarSelection: Codable {
        case activity
        case allProjects
        case project(UUID)

        private enum CodingKeys: String, CodingKey {
            case kind
            case projectID
        }

        private enum Kind: String, Codable {
            case activity
            case allProjects
            case project
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .kind)

            switch kind {
            case .activity:
                self = .activity
            case .allProjects:
                self = .allProjects
            case .project:
                self = try .project(container.decode(UUID.self, forKey: .projectID))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .activity:
                try container.encode(Kind.activity, forKey: .kind)
            case .allProjects:
                try container.encode(Kind.allProjects, forKey: .kind)
            case let .project(projectID):
                try container.encode(Kind.project, forKey: .kind)
                try container.encode(projectID, forKey: .projectID)
            }
        }

        init(sidebarSelection: SidebarSelection) {
            switch sidebarSelection {
            case .activity:
                self = .activity
            case .allProjects:
                self = .allProjects
            case let .project(projectID):
                self = .project(projectID)
            }
        }

        var sidebarSelection: SidebarSelection {
            switch self {
            case .activity:
                .activity
            case .allProjects:
                .allProjects
            case let .project(projectID):
                .project(projectID)
            }
        }
    }

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "TicketParty.navigationSelection.v1"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func loadSidebarSelection() -> SidebarSelection? {
        loadState().sidebarSelection?.sidebarSelection
    }

    func saveSidebarSelection(_ selection: SidebarSelection?) {
        var state = loadState()
        state.sidebarSelection = selection.map(PersistedSidebarSelection.init(sidebarSelection:))
        persist(state)
    }

    func loadSelectedTicketID(for projectID: UUID) -> UUID? {
        let state = loadState()
        guard let rawTicketID = state.selectedTicketIDsByProjectID[projectID.uuidString] else {
            return nil
        }
        return UUID(uuidString: rawTicketID)
    }

    func saveSelectedTicketID(_ ticketID: UUID?, for projectID: UUID) {
        var state = loadState()
        let projectKey = projectID.uuidString

        if let ticketID {
            state.selectedTicketIDsByProjectID[projectKey] = ticketID.uuidString
        } else {
            state.selectedTicketIDsByProjectID.removeValue(forKey: projectKey)
        }

        persist(state)
    }

    private func loadState() -> PersistedState {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return .empty
        }

        return (try? JSONDecoder().decode(PersistedState.self, from: data)) ?? .empty
    }

    private func persist(_ state: PersistedState) {
        guard let encoded = try? JSONEncoder().encode(state) else {
            return
        }
        userDefaults.set(encoded, forKey: storageKey)
    }
}
