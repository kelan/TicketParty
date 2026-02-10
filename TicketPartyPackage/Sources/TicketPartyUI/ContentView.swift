//
//  ContentView.swift
//  TicketParty
//
//  Created by Kelan Champagne on 2/9/26.
//

import SwiftUI

public struct TicketPartyRootView: View {
    @State private var selection: SidebarSelection? = .activity

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    NavigationLink(value: SidebarSelection.activity) {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                    }

                    NavigationLink(value: SidebarSelection.allProjects) {
                        Label("All Projects", systemImage: "tablecells")
                    }
                }

                Section("Projects") {
                    ForEach(StubData.projects) { project in
                        NavigationLink(value: SidebarSelection.project(project.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(.headline)
                                Text(project.latestStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("TicketParty")
            #if os(macOS)
                .navigationSplitViewColumnWidth(min: 230, ideal: 280)
            #endif
        } detail: {
            switch selection ?? .activity {
            case .activity:
                ActivityView()

            case .allProjects:
                OverallKanbanView()

            case let .project(projectID):
                if let project = StubData.project(id: projectID) {
                    ProjectDetailView(project: project)
                        .id(project.id)
                } else {
                    ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
                }
            }
        }
    }
}

public struct TicketPartySettingsView: View {
    public init() {}

    public var body: some View {
        Form {
            Section("General") {
                LabeledContent("Theme", value: "System")
                LabeledContent("Notifications", value: "Enabled")
            }

            Section("Integrations") {
                LabeledContent("Sync Provider", value: "Not Configured")
                LabeledContent("Issue Tracker", value: "Not Configured")
            }

            Section("Diagnostics") {
                LabeledContent("Environment", value: "Stub")
                LabeledContent("Build", value: "Debug")
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
    }
}

private enum SidebarSelection: Hashable {
    case activity
    case allProjects
    case project(String)
}

private struct ActivityView: View {
    var body: some View {
        List(StubData.activityEvents) { event in
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline)
                Text(event.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(event.timestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Activity")
    }
}

private struct OverallKanbanView: View {
    private let states = StubTicketState.allCases

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Project")
                        .font(.caption.weight(.semibold))
                        .frame(width: 180, alignment: .leading)

                    ForEach(states) { state in
                        Text(state.title)
                            .font(.caption.weight(.semibold))
                            .frame(width: 210, alignment: .leading)
                    }
                }

                ForEach(StubData.projects) { project in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.headline)
                            Text(project.latestStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 180, alignment: .leading)

                        ForEach(states) { state in
                            KanbanCell(tickets: project.tickets.filter { $0.state == state })
                                .frame(width: 210, alignment: .leading)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("All Projects")
    }
}

private struct KanbanCell: View {
    let tickets: [StubTicket]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(tickets.count) ticket\(tickets.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if tickets.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tickets.prefix(2)) { ticket in
                    Text(ticket.title)
                        .font(.caption)
                        .lineLimit(1)
                }

                if tickets.count > 2 {
                    Text("+\(tickets.count - 2) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProjectDetailView: View {
    let project: StubProject
    @State private var selectedTicketID: String?
    @State private var selectedStateFilter: StubTicketState?
    @State private var showHighPriorityOnly = false
    @State private var searchText = ""

    var body: some View {
        ProjectWorkspaceView(
            project: project,
            selectedTicketID: $selectedTicketID,
            selectedStateFilter: $selectedStateFilter,
            showHighPriorityOnly: $showHighPriorityOnly,
            searchText: $searchText
        )
        .navigationTitle(project.name)
        .onAppear {
            if selectedTicketID == nil {
                selectedTicketID = project.tickets.first?.id
            }
        }
    }
}

private struct ProjectWorkspaceView: View {
    let project: StubProject
    @Binding var selectedTicketID: String?
    @Binding var selectedStateFilter: StubTicketState?
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String

    private var filteredTickets: [StubTicket] {
        project.tickets.filter { ticket in
            let stateMatches = selectedStateFilter == nil || ticket.state == selectedStateFilter
            let priorityMatches = showHighPriorityOnly == false || ticket.priority == .high
            let searchMatches = searchText.isEmpty || ticket.title.localizedCaseInsensitiveContains(searchText)
            return stateMatches && priorityMatches && searchMatches
        }
    }

    private var selectedTicket: StubTicket? {
        guard let selectedTicketID else { return nil }
        return filteredTickets.first { $0.id == selectedTicketID }
    }

    var body: some View {
        HStack(spacing: 0) {
            ProjectFiltersPanel(
                selectedStateFilter: $selectedStateFilter,
                showHighPriorityOnly: $showHighPriorityOnly,
                searchText: $searchText
            )
            .frame(width: 220)

            Divider()

            List(filteredTickets, selection: $selectedTicketID) { ticket in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ticket.title)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(ticket.state.title)
                        Text(ticket.priority.title)
                        Text(ticket.assignee)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 320, idealWidth: 380)

            Divider()

            ProjectTicketDetailPanel(ticket: selectedTicket)
                .frame(minWidth: 300, idealWidth: 380)
        }
        .onChange(of: filteredTickets.map(\.id)) { _, ids in
            if let selectedTicketID, ids.contains(selectedTicketID) {
                return
            }
            self.selectedTicketID = ids.first
        }
    }
}

private struct ProjectFiltersPanel: View {
    @Binding var selectedStateFilter: StubTicketState?
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters")
                .font(.headline)

            Picker("State", selection: $selectedStateFilter) {
                Text("All States").tag(StubTicketState?.none)
                ForEach(StubTicketState.allCases) { state in
                    Text(state.title).tag(Optional(state))
                }
            }
            .pickerStyle(.menu)

            Toggle("High Priority Only", isOn: $showHighPriorityOnly)

            TextField("Search tickets", text: $searchText)

            Spacer()
        }
        .padding(12)
    }
}

private struct ProjectTicketDetailPanel: View {
    let ticket: StubTicket?

    var body: some View {
        Group {
            if let ticket {
                Form {
                    Section("Ticket") {
                        LabeledContent("Title", value: ticket.title)
                        LabeledContent("State", value: ticket.state.title)
                        LabeledContent("Priority", value: ticket.priority.title)
                        LabeledContent("Assignee", value: ticket.assignee)
                    }

                    Section("Latest Update") {
                        Text(ticket.latestNote)
                    }
                }
            } else {
                ContentUnavailableView("Select a Ticket", systemImage: "doc.text")
            }
        }
    }
}

#Preview {
    TicketPartyRootView()
}

private enum StubTicketState: String, CaseIterable, Identifiable {
    case backlog
    case inProgress
    case blocked
    case review
    case done

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .backlog:
            return "Backlog"
        case .inProgress:
            return "In Progress"
        case .blocked:
            return "Blocked"
        case .review:
            return "Review"
        case .done:
            return "Done"
        }
    }
}

private enum StubPriority: String {
    case low
    case medium
    case high

    var title: String {
        rawValue.capitalized
    }
}

private struct StubTicket: Identifiable, Hashable {
    let id: String
    let title: String
    let state: StubTicketState
    let priority: StubPriority
    let assignee: String
    let latestNote: String
}

private struct StubProject: Identifiable, Hashable {
    let id: String
    let name: String
    let latestStatus: String
    let tickets: [StubTicket]
}

private struct StubActivityEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let timestamp: String
}

private enum StubData {
    static let projects: [StubProject] = [
        StubProject(
            id: "project_growth",
            name: "Growth Site",
            latestStatus: "In Progress - waiting on analytics backfill",
            tickets: [
                StubTicket(
                    id: "growth_1",
                    title: "Plan release checklist",
                    state: .review,
                    priority: .high,
                    assignee: "Kelan",
                    latestNote: "Checklist drafted and in stakeholder review."
                ),
                StubTicket(
                    id: "growth_2",
                    title: "Revise pricing page copy",
                    state: .inProgress,
                    priority: .medium,
                    assignee: "Avery",
                    latestNote: "Legal language updates still pending."
                ),
                StubTicket(
                    id: "growth_3",
                    title: "Fix attribution mismatch",
                    state: .blocked,
                    priority: .high,
                    assignee: "Maya",
                    latestNote: "Blocked by delayed warehouse replay job."
                ),
                StubTicket(
                    id: "growth_4",
                    title: "New referral CTA",
                    state: .backlog,
                    priority: .low,
                    assignee: "Riley",
                    latestNote: "Pending design exploration."
                ),
            ]
        ),
        StubProject(
            id: "project_ios",
            name: "iOS App",
            latestStatus: "Review queue growing",
            tickets: [
                StubTicket(
                    id: "ios_1",
                    title: "Refactor onboarding flow",
                    state: .inProgress,
                    priority: .high,
                    assignee: "Noah",
                    latestNote: "Feature flag enabled for internal builds."
                ),
                StubTicket(
                    id: "ios_2",
                    title: "Fix settings crash",
                    state: .done,
                    priority: .high,
                    assignee: "Sam",
                    latestNote: "Patched in build 42 and verified."
                ),
                StubTicket(
                    id: "ios_3",
                    title: "Polish push opt-in copy",
                    state: .review,
                    priority: .medium,
                    assignee: "Taylor",
                    latestNote: "Awaiting PM approval."
                ),
            ]
        ),
        StubProject(
            id: "project_ops",
            name: "Ops Automation",
            latestStatus: "Stable this week",
            tickets: [
                StubTicket(
                    id: "ops_1",
                    title: "Consolidate CI templates",
                    state: .review,
                    priority: .medium,
                    assignee: "Jordan",
                    latestNote: "Cross-team migration playbook is ready."
                ),
                StubTicket(
                    id: "ops_2",
                    title: "Rotate stale credentials",
                    state: .done,
                    priority: .high,
                    assignee: "Casey",
                    latestNote: "Rotation complete in all production environments."
                ),
                StubTicket(
                    id: "ops_3",
                    title: "Audit deployment alerts",
                    state: .backlog,
                    priority: .low,
                    assignee: "Morgan",
                    latestNote: "Initial audit scope drafted."
                ),
            ]
        ),
    ]

    static let activityEvents: [StubActivityEvent] = [
        StubActivityEvent(
            id: "activity_1",
            title: "Growth Site moved to Review",
            subtitle: "Plan release checklist is waiting for sign-off",
            timestamp: "Today 9:42 AM"
        ),
        StubActivityEvent(
            id: "activity_2",
            title: "iOS App crash fix completed",
            subtitle: "Settings crash patch marked Done",
            timestamp: "Today 8:17 AM"
        ),
        StubActivityEvent(
            id: "activity_3",
            title: "Ops Automation credential rotation finished",
            subtitle: "Production secrets rotated and validated",
            timestamp: "Yesterday 5:05 PM"
        ),
    ]

    static func project(id: String) -> StubProject? {
        projects.first { $0.id == id }
    }
}
