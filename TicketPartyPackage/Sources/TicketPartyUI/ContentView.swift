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
    @Query(sort: [SortDescriptor(\Project.updatedAt, order: .forward)]) private var projects: [Project]
    @Query(sort: [SortDescriptor(\Ticket.updatedAt, order: .reverse)]) private var tickets: [Ticket]

    @State private var selection: SidebarSelection?
    @State private var isPresentingCreateProject = false
    @State private var isPresentingCreateTicket = false
    @State private var ticketDraft = TicketDraft()
    @State private var codexViewModel = CodexViewModel()
    private let selectionStore: NavigationSelectionStore

    public init() {
        let selectionStore = NavigationSelectionStore()
        self.selectionStore = selectionStore
        _selection = State(initialValue: selectionStore.loadSidebarSelection() ?? .activity)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    NavigationLink(value: SidebarSelection.activity) {
                        SidebarActivityStatusLabel(status: codexViewModel.supervisorHealth)
                    }

                    NavigationLink(value: SidebarSelection.allProjects) {
                        Label("All Projects", systemImage: "tablecells")
                    }
                }

                Section {
                    ForEach(projects, id: \.id) { project in
                        NavigationLink(value: SidebarSelection.project(project.id)) {
                            let sidebarStatus = sidebarStatus(for: project)
                            let agentStatus = codexViewModel.status(for: project.id)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(project.name)
                                        .font(.headline)
                                }

                                Text("Updated \(updatedSubtitle(for: sidebarStatus.lastUpdated))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(agentStatusColor(agentStatus))
                                        .frame(width: 8, height: 8)

                                    Text(agentStatusLabel(agentStatus))
                                        .font(.caption2)
                                        .foregroundStyle(agentStatusColor(agentStatus))
                                        .lineLimit(1)
                                }

                                Text("\(sidebarStatus.inProgressCount) in progress / \(sidebarStatus.backlogCount) backlog")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("Projects")
                            .font(.title)
                        Spacer()
                        Button {
                            isPresentingCreateProject = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title2)
                                .padding(12)
                        }
                        .buttonStyle(.plain)
                        .help("Create new Project")
                    }
                }
            }
            .navigationTitle("TicketParty")
            #if os(macOS)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230)
            #endif
        } detail: {
            switch selection ?? .activity {
            case .activity:
                ActivityView(projects: projects, tickets: tickets)

            case .allProjects:
                OverallKanbanView(projects: projects)

            case let .project(projectID):
                if let project = projects.first(where: { $0.id == projectID }) {
                    ProjectDetailView(
                        project: project,
                        initialSelectedTicketID: selectionStore.loadSelectedTicketID(for: project.id),
                        onSelectedTicketChange: { ticketID in
                            guard let ticketID else { return }
                            selectionStore.saveSelectedTicketID(ticketID, for: project.id)
                        },
                        onRequestNewTicket: presentNewTicketSheet
                    )
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
        .sheet(isPresented: $isPresentingCreateTicket) {
            TicketEditorSheet(
                title: "New Ticket",
                submitLabel: "Create",
                projects: projects,
                showsAddToTopOfBacklogOption: true,
                initialDraft: ticketDraft,
                onSubmit: createTicket
            )
        }
        .onAppear {
            codexViewModel.configure(modelContext: modelContext)
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
        .onChange(of: selection) { _, newSelection in
            selectionStore.saveSidebarSelection(newSelection)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ticketPartyNewTicketRequested)) { _ in
            presentNewTicketSheet()
        }
        .environment(codexViewModel)
    }

    private func createProject(_ draft: ProjectDraft) {
        let project = Project(
            name: draft.name,
            statusText: draft.statusText,
            summary: draft.summary,
            workingDirectory: draft.normalizedWorkingDirectory,
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

    private func createTicket(_ draft: TicketDraft) {
        let normalizedDraft = draft.normalized
        guard let projectID = normalizedDraft.projectID else { return }

        var descriptor = FetchDescriptor<Ticket>(sortBy: [SortDescriptor(\Ticket.ticketNumber, order: .reverse)])
        descriptor.fetchLimit = 1

        let currentMaxNumber = (try? modelContext.fetch(descriptor).first?.ticketNumber) ?? 0
        let nextTicketNumber = currentMaxNumber + 1
        let nextOrderKey = (try? TicketOrdering.nextSeedOrderKey(context: modelContext, projectID: projectID)) ?? TicketOrdering.keyStep

        let ticket = Ticket(
            ticketNumber: nextTicketNumber,
            displayID: "TT-\(nextTicketNumber)",
            projectID: projectID,
            orderKey: nextOrderKey,
            title: normalizedDraft.title,
            description: normalizedDraft.description,
            size: normalizedDraft.size,
            stateID: TicketQuickStatus.backlog.stateID,
            createdAt: .now,
            updatedAt: .now
        )

        modelContext.insert(ticket)

        do {
            if normalizedDraft.addToTopOfBacklog {
                let afterTicketID = firstBacklogTicketID(projectID: projectID, excluding: ticket.id)
                try TicketOrdering.moveTicket(
                    context: modelContext,
                    ticketID: ticket.id,
                    projectID: projectID,
                    scopeStateIDs: backlogStateIDs,
                    beforeTicketID: nil,
                    afterTicketID: afterTicketID
                )
            } else {
                try modelContext.save()
            }

            selection = .project(projectID)
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }

    private var backlogStateIDs: Set<UUID> {
        [
            TicketQuickStatus.backlog.stateID,
            TicketQuickStatus.needsThinking.stateID,
            TicketQuickStatus.readyToImplement.stateID,
            TicketQuickStatus.blocked.stateID,
        ]
    }

    private func firstBacklogTicketID(projectID: UUID, excluding excludedTicketID: UUID) -> UUID? {
        let descriptor = FetchDescriptor<Ticket>(
            predicate: #Predicate<Ticket> { ticket in
                ticket.projectID == projectID &&
                    ticket.closedAt == nil &&
                    ticket.archivedAt == nil
            },
            sortBy: [SortDescriptor(\Ticket.orderKey, order: .forward), SortDescriptor(\Ticket.createdAt, order: .forward)]
        )

        guard let activeProjectTickets = try? modelContext.fetch(descriptor) else {
            return nil
        }

        return activeProjectTickets.first { ticket in
            ticket.id != excludedTicketID &&
                backlogStateIDs.contains(ticket.stateID ?? TicketQuickStatus.backlog.stateID)
        }?.id
    }

    private func presentNewTicketSheet(_ preferredProjectID: UUID? = nil) {
        let currentProjectID: UUID? = if case let .project(projectID) = selection {
            projectID
        } else {
            nil
        }

        ticketDraft = TicketDraft(projectID: preferredProjectID ?? currentProjectID ?? projects.first?.id)
        isPresentingCreateTicket = true
    }

    private func sidebarStatus(for project: Project) -> ProjectSidebarStatus {
        var latestUpdate: Date?
        var inProgressCount = 0
        var backlogCount = 0

        for ticket in tickets where ticket.projectID == project.id && ticket.archivedAt == nil {
            latestUpdate = max(latestUpdate ?? ticket.updatedAt, ticket.updatedAt)

            switch ticket.quickStatus {
            case .inProgress, .review:
                inProgressCount += 1
            case .backlog, .needsThinking, .readyToImplement, .blocked:
                backlogCount += 1
            case .done, .skipped, .duplicate:
                break
            }
        }

        let lastUpdated = max(project.updatedAt, latestUpdate ?? project.updatedAt)

        return ProjectSidebarStatus(
            lastUpdated: lastUpdated,
            inProgressCount: inProgressCount,
            backlogCount: backlogCount
        )
    }

    private func agentStatusLabel(_ status: CodexProjectStatus) -> String {
        switch status {
        case .running:
            return "Agent running"
        case .starting:
            return "Agent starting"
        case .stopped:
            return "Agent stopped"
        case .error:
            return "Agent error"
        }
    }

    private func agentStatusColor(_ status: CodexProjectStatus) -> Color {
        switch status {
        case .running:
            return .green
        case .starting:
            return .orange
        case .error:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func updatedSubtitle(for date: Date) -> String {
        let now = Date()
        let seconds = max(0, now.timeIntervalSince(date))

        if seconds < 60 {
            return "just now"
        }

        if seconds < 3_600 {
            let minutes = Int(seconds / 60)
            return "\(minutes) min ago"
        }

        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            return "\(hours) hr ago"
        }

        if seconds < 172_800 {
            let days = Int(seconds / 86_400)
            return "\(days) day ago"
        }

        return Self.sidebarDateFormatter.string(from: date)
    }

    private static let sidebarDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct ProjectSidebarStatus {
    let lastUpdated: Date
    let inProgressCount: Int
    let backlogCount: Int
}

private struct SidebarActivityStatusLabel: View {
    let status: CodexSupervisorHealthStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Activity", systemImage: "clock.arrow.circlepath")
                .lineLimit(1)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusTitle)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(statusColor)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
        .help(status.detail)
    }

    private var statusTitle: String {
        switch status {
        case .healthy:
            return "Supervisor running"
        case .notRunning:
            return "Supervisor not running"
        case .staleRecord:
            return "Supervisor stale"
        case .unreachable:
            return "Supervisor unreachable"
        case .handshakeFailed:
            return "Supervisor handshake failed"
        case .invalidRecord:
            return "Supervisor invalid record"
        }
    }

    private var statusColor: Color {
        switch status {
        case .healthy:
            return .green
        case .notRunning:
            return .secondary
        case .staleRecord, .unreachable:
            return .orange
        case .handshakeFailed, .invalidRecord:
            return .red
        }
    }
}

#Preview {
    TicketPartyRootView()
        .modelContainer(previewContainer)
}

@MainActor private let previewContainer: ModelContainer = {
    let schema = Schema([Project.self, Ticket.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

    do {
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let projects: [Project] = SampleData.projects.map { stubProject in
            Project(
                id: stubProject.id,
                name: stubProject.name,
                statusText: stubProject.statusText,
                summary: stubProject.summary
            )
        }

        projects.forEach(context.insert)

        var ticketNumber = 1
        for project in projects {
            let previewTickets = SampleData.tickets(for: project)

            for ticket in previewTickets {
                context.insert(
                    Ticket(
                        ticketNumber: ticketNumber,
                        displayID: "TT-\(ticketNumber)",
                        projectID: project.id,
                        orderKey: Int64(ticketNumber) * TicketOrdering.keyStep,
                        title: ticket.title,
                        description: ticket.latestNote,
                        size: ticket.size.ticketSize,
                        stateID: ticket.state.ticketQuickStatus.stateID
                    )
                )
                ticketNumber += 1
            }
        }

        try context.save()
        return container
    } catch {
        fatalError("Failed to create preview container: \(error)")
    }
}()
