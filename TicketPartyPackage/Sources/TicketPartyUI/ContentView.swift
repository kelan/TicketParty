//
//  ContentView.swift
//  TicketParty
//
//  Created by Kelan Champagne on 2/9/26.
//

import SwiftData
import SwiftUI
import TicketPartyDataStore

public struct TicketPartyRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Project.updatedAt, order: .reverse), SortDescriptor(\Project.name, order: .forward)]) private var projects: [Project]

    @State private var selection: SidebarSelection? = .activity
    @State private var isPresentingCreateProject = false

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

                Section {
                    ForEach(projects, id: \.id) { project in
                        NavigationLink(value: SidebarSelection.project(project.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(.headline)
                                Text(project.sidebarSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
                        Button {
                            isPresentingCreateProject = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("New Project")
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
                OverallKanbanView(projects: projects)

            case let .project(projectID):
                if let project = projects.first(where: { $0.id == projectID }) {
                    ProjectDetailView(project: project)
                        .id(project.id)
                } else {
                    ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
                }
            }
        }
        .sheet(isPresented: $isPresentingCreateProject) {
            ProjectEditorSheet(
                title: "New Project",
                submitLabel: "Create",
                initialDraft: ProjectDraft(),
                onSubmit: createProject
            )
        }
        .onChange(of: projects.map(\.id)) { _, projectIDs in
            guard let selection else {
                self.selection = .activity
                return
            }

            if case let .project(projectID) = selection,
               projectIDs.contains(projectID) == false
            {
                self.selection = .activity
            }
        }
    }

    private func createProject(_ draft: ProjectDraft) {
        let project = Project(
            name: draft.name,
            statusText: draft.statusText,
            summary: draft.summary,
            createdAt: .now,
            updatedAt: .now
        )

        modelContext.insert(project)

        do {
            try modelContext.save()
            selection = .project(project.id)
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
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
    case project(UUID)
}

private struct ProjectDraft: Equatable {
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

private extension Project {
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

private struct ActivityView: View {
    var body: some View {
        List(SampleData.activityEvents) { event in
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
    let projects: [Project]
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

                ForEach(projects, id: \.id) { project in
                    let tickets = SampleData.tickets(for: project)

                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.headline)
                            Text(project.sidebarSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 180, alignment: .leading)

                        ForEach(states) { state in
                            KanbanCell(tickets: tickets.filter { $0.state == state })
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
    @Environment(\.modelContext) private var modelContext
    @Bindable var project: Project

    @State private var selectedTicketID: String?
    @State private var selectedStateFilter: StubTicketState?
    @State private var showHighPriorityOnly = false
    @State private var searchText = ""
    @State private var isPresentingEditProject = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.title2.weight(.semibold))

                Button {
                    isPresentingEditProject = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help("Edit Project")

                Spacer()

                Text(project.sidebarSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ProjectWorkspaceView(
                project: project,
                selectedTicketID: $selectedTicketID,
                selectedStateFilter: $selectedStateFilter,
                showHighPriorityOnly: $showHighPriorityOnly,
                searchText: $searchText
            )
        }
        .sheet(isPresented: $isPresentingEditProject) {
            ProjectEditorSheet(
                title: "Edit Project",
                submitLabel: "Save",
                initialDraft: ProjectDraft(
                    name: project.name,
                    statusText: project.statusText,
                    summary: project.summary
                ),
                onSubmit: applyProjectEdits
            )
        }
        .onAppear {
            if selectedTicketID == nil {
                selectedTicketID = SampleData.tickets(for: project).first?.id
            }
        }
    }

    private func applyProjectEdits(_ draft: ProjectDraft) {
        project.name = draft.name
        project.statusText = draft.statusText
        project.summary = draft.summary
        project.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }
}

private struct ProjectWorkspaceView: View {
    let project: Project
    @Binding var selectedTicketID: String?
    @Binding var selectedStateFilter: StubTicketState?
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String

    private var tickets: [StubTicket] {
        SampleData.tickets(for: project)
    }

    private var filteredTickets: [StubTicket] {
        tickets.filter { ticket in
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

private struct ProjectEditorSheet: View {
    let title: String
    let submitLabel: String
    let onSubmit: (ProjectDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProjectDraft

    init(
        title: String,
        submitLabel: String,
        initialDraft: ProjectDraft,
        onSubmit: @escaping (ProjectDraft) -> Void
    ) {
        self.title = title
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Title", text: $draft.name)
                    TextField("Current Status", text: $draft.statusText)
                }

                Section("Details") {
                    TextField("Summary", text: $draft.summary, axis: .vertical)
                        .lineLimit(3 ... 6)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(submitLabel) {
                        onSubmit(draft.normalized)
                        dismiss()
                    }
                    .disabled(draft.normalized.name.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

#Preview {
    TicketPartyRootView()
        .modelContainer(for: [Project.self], inMemory: true)
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

private struct StubActivityEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let timestamp: String
}

private enum SampleData {
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

    static func tickets(for project: Project) -> [StubTicket] {
        let baseTickets: [StubTicket] = [
            StubTicket(
                id: "1",
                title: "Plan release checklist",
                state: .review,
                priority: .high,
                assignee: "Kelan",
                latestNote: "Checklist drafted and in stakeholder review."
            ),
            StubTicket(
                id: "2",
                title: "Revise pricing page copy",
                state: .inProgress,
                priority: .medium,
                assignee: "Avery",
                latestNote: "Legal language updates still pending."
            ),
            StubTicket(
                id: "3",
                title: "Fix attribution mismatch",
                state: .blocked,
                priority: .high,
                assignee: "Maya",
                latestNote: "Blocked by delayed warehouse replay job."
            ),
            StubTicket(
                id: "4",
                title: "New referral CTA",
                state: .backlog,
                priority: .low,
                assignee: "Riley",
                latestNote: "Pending design exploration."
            ),
        ]

        return baseTickets.map { ticket in
            StubTicket(
                id: "\(project.id.uuidString)_\(ticket.id)",
                title: ticket.title,
                state: ticket.state,
                priority: ticket.priority,
                assignee: ticket.assignee,
                latestNote: ticket.latestNote
            )
        }
    }
}
