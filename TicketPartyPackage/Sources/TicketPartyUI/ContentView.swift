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
    private let states = StubTaskState.allCases

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
                            KanbanCell(tasks: project.tasks.filter { $0.state == state })
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
    let tasks: [StubTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(tasks.count) task\(tasks.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if tasks.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tasks.prefix(2)) { task in
                    Text(task.title)
                        .font(.caption)
                        .lineLimit(1)
                }

                if tasks.count > 2 {
                    Text("+\(tasks.count - 2) more")
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
    @State private var selectedTaskID: String?
    @State private var selectedStateFilter: StubTaskState?
    @State private var showHighPriorityOnly = false
    @State private var searchText = ""

    var body: some View {
        ProjectWorkspaceView(
            project: project,
            selectedTaskID: $selectedTaskID,
            selectedStateFilter: $selectedStateFilter,
            showHighPriorityOnly: $showHighPriorityOnly,
            searchText: $searchText
        )
        .navigationTitle(project.name)
        .onAppear {
            if selectedTaskID == nil {
                selectedTaskID = project.tasks.first?.id
            }
        }
    }
}

private struct ProjectWorkspaceView: View {
    let project: StubProject
    @Binding var selectedTaskID: String?
    @Binding var selectedStateFilter: StubTaskState?
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String

    private var filteredTasks: [StubTask] {
        project.tasks.filter { task in
            let stateMatches = selectedStateFilter == nil || task.state == selectedStateFilter
            let priorityMatches = showHighPriorityOnly == false || task.priority == .high
            let searchMatches = searchText.isEmpty || task.title.localizedCaseInsensitiveContains(searchText)
            return stateMatches && priorityMatches && searchMatches
        }
    }

    private var selectedTask: StubTask? {
        guard let selectedTaskID else { return nil }
        return filteredTasks.first { $0.id == selectedTaskID }
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

            List(filteredTasks, selection: $selectedTaskID) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(task.state.title)
                        Text(task.priority.title)
                        Text(task.assignee)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 320, idealWidth: 380)

            Divider()

            ProjectTaskDetailPanel(task: selectedTask)
                .frame(minWidth: 300, idealWidth: 380)
        }
        .onChange(of: filteredTasks.map(\.id)) { _, ids in
            if let selectedTaskID, ids.contains(selectedTaskID) {
                return
            }
            self.selectedTaskID = ids.first
        }
    }
}

private struct ProjectFiltersPanel: View {
    @Binding var selectedStateFilter: StubTaskState?
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters")
                .font(.headline)

            Picker("State", selection: $selectedStateFilter) {
                Text("All States").tag(Optional<StubTaskState>.none)
                ForEach(StubTaskState.allCases) { state in
                    Text(state.title).tag(Optional(state))
                }
            }
            .pickerStyle(.menu)

            Toggle("High Priority Only", isOn: $showHighPriorityOnly)

            TextField("Search tasks", text: $searchText)

            Spacer()
        }
        .padding(12)
    }
}

private struct ProjectTaskDetailPanel: View {
    let task: StubTask?

    var body: some View {
        Group {
            if let task {
                Form {
                    Section("Task") {
                        LabeledContent("Title", value: task.title)
                        LabeledContent("State", value: task.state.title)
                        LabeledContent("Priority", value: task.priority.title)
                        LabeledContent("Assignee", value: task.assignee)
                    }

                    Section("Latest Update") {
                        Text(task.latestNote)
                    }
                }
            } else {
                ContentUnavailableView("Select a Task", systemImage: "doc.text")
            }
        }
    }
}

#Preview {
    TicketPartyRootView()
}

private enum StubTaskState: String, CaseIterable, Identifiable {
    case backlog
    case inProgress
    case blocked
    case review
    case done

    var id: String { rawValue }

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

    var title: String { rawValue.capitalized }
}

private struct StubTask: Identifiable, Hashable {
    let id: String
    let title: String
    let state: StubTaskState
    let priority: StubPriority
    let assignee: String
    let latestNote: String
}

private struct StubProject: Identifiable, Hashable {
    let id: String
    let name: String
    let latestStatus: String
    let tasks: [StubTask]
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
            tasks: [
                StubTask(
                    id: "growth_1",
                    title: "Plan release checklist",
                    state: .review,
                    priority: .high,
                    assignee: "Kelan",
                    latestNote: "Checklist drafted and in stakeholder review."
                ),
                StubTask(
                    id: "growth_2",
                    title: "Revise pricing page copy",
                    state: .inProgress,
                    priority: .medium,
                    assignee: "Avery",
                    latestNote: "Legal language updates still pending."
                ),
                StubTask(
                    id: "growth_3",
                    title: "Fix attribution mismatch",
                    state: .blocked,
                    priority: .high,
                    assignee: "Maya",
                    latestNote: "Blocked by delayed warehouse replay job."
                ),
                StubTask(
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
            tasks: [
                StubTask(
                    id: "ios_1",
                    title: "Refactor onboarding flow",
                    state: .inProgress,
                    priority: .high,
                    assignee: "Noah",
                    latestNote: "Feature flag enabled for internal builds."
                ),
                StubTask(
                    id: "ios_2",
                    title: "Fix settings crash",
                    state: .done,
                    priority: .high,
                    assignee: "Sam",
                    latestNote: "Patched in build 42 and verified."
                ),
                StubTask(
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
            tasks: [
                StubTask(
                    id: "ops_1",
                    title: "Consolidate CI templates",
                    state: .review,
                    priority: .medium,
                    assignee: "Jordan",
                    latestNote: "Cross-team migration playbook is ready."
                ),
                StubTask(
                    id: "ops_2",
                    title: "Rotate stale credentials",
                    state: .done,
                    priority: .high,
                    assignee: "Casey",
                    latestNote: "Rotation complete in all production environments."
                ),
                StubTask(
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
