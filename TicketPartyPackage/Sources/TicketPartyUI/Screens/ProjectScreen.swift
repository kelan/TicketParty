import SwiftData
import SwiftUI
import TicketPartyDataStore

struct ProjectDetailView: View {
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
                selectedTicketID = PreviewRuntime.usesStubData ? SampleData.tickets(for: project).first?.id : nil
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
        PreviewRuntime.usesStubData ? SampleData.tickets(for: project) : []
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

struct ProjectEditorSheet: View {
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
    ProjectDetailView(project: ProjectPreviewData.project)
        .modelContainer(ProjectPreviewData.container)
}

@MainActor
private enum ProjectPreviewData {
    static let container: ModelContainer = {
        let schema = Schema([Project.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create preview container: \(error)")
        }
    }()

    static let project: Project = {
        let project = Project(
            name: "Growth Site",
            statusText: "Release candidate",
            summary: "Final QA and launch checklist in progress."
        )

        let context = container.mainContext
        context.insert(project)

        do {
            try context.save()
        } catch {
            // Preview-only context; ignore save failures.
        }

        return project
    }()
}
