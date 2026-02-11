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
    @State private var isPresentingCreateTicket = false
    @State private var ticketDraft = TicketDraft()
    @State private var codexViewModel = CodexViewModel()

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

                    NavigationLink(value: SidebarSelection.codex) {
                        Label("Agents", systemImage: "terminal")
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
                ActivityView()

            case .allProjects:
                OverallKanbanView(projects: projects)

            case .codex:
                CodexStatusView(projects: projects)

            case let .project(projectID):
                if let project = projects.first(where: { $0.id == projectID }) {
                    ProjectDetailView(project: project, onRequestNewTicket: presentNewTicketSheet)
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
                initialDraft: ticketDraft,
                onSubmit: createTicket
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
            try modelContext.save()
            selection = .project(projectID)
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
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
