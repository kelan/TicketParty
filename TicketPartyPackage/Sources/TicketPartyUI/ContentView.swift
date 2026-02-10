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

#Preview {
    TicketPartyRootView()
        .modelContainer(for: [Project.self], inMemory: true)
}
