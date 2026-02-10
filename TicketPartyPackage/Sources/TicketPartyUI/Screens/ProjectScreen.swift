import SwiftData
import SwiftUI
import TicketPartyDataStore
import TicketPartyModels

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Ticket.orderKey, order: .forward), SortDescriptor(\Ticket.createdAt, order: .forward)]) private var allTickets: [Ticket]

    @Bindable var project: Project
    let onRequestNewTicket: (UUID?) -> Void

    @State private var selectedTicketID: UUID?
    @State private var selectedPriorityFilter: TicketPriority?
    @State private var showHighPriorityOnly = false
    @State private var searchText = ""
    @State private var isPresentingEditProject = false
    @State private var ticketEditSession: TicketEditSession?

    init(project: Project, onRequestNewTicket: @escaping (UUID?) -> Void = { _ in }) {
        self.project = project
        self.onRequestNewTicket = onRequestNewTicket
    }

    private var tickets: [Ticket] {
        allTickets.filter { ticket in
            ticket.archivedAt == nil &&
                ticket.closedAt == nil &&
                ticket.projectID == project.id
        }
    }

    private var filteredTickets: [Ticket] {
        tickets.filter { ticket in
            let priorityMatches = selectedPriorityFilter == nil || ticket.priority == selectedPriorityFilter
            let highPriorityMatches = showHighPriorityOnly == false || ticket.priority == .high || ticket.priority == .urgent
            let searchMatches = searchText.isEmpty || ticket.title.localizedCaseInsensitiveContains(searchText)
            return priorityMatches && highPriorityMatches && searchMatches
        }
    }

    private var isManualSortEnabled: Bool {
        selectedPriorityFilter == nil && showHighPriorityOnly == false && searchText.isEmpty
    }

    private var selectedTicket: Ticket? {
        guard let selectedTicketID else { return nil }
        return tickets.first { $0.id == selectedTicketID }
    }

    private var availableProjects: [Project] {
        [project]
    }

    var body: some View {
        ProjectWorkspaceView(
            filteredTickets: filteredTickets,
            selectedTicketID: $selectedTicketID,
            selectedPriorityFilter: $selectedPriorityFilter,
            showHighPriorityOnly: $showHighPriorityOnly,
            searchText: $searchText,
            selectedTicket: selectedTicket,
            isManualSortEnabled: isManualSortEnabled,
            onMoveTickets: moveTickets
        )
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    onRequestNewTicket(project.id)
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Ticket")

                if let selectedTicket {
                    Button {
                        ticketEditSession = TicketEditSession(id: selectedTicket.id)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .help("Edit Ticket")
                }

                Button {
                    isPresentingEditProject = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Edit Project")
            }
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
        .sheet(item: $ticketEditSession) { session in
            if let ticket = allTickets.first(where: { $0.id == session.id }) {
                TicketEditorSheet(
                    title: "Edit Ticket",
                    submitLabel: "Save",
                    projects: availableProjects,
                    initialDraft: TicketDraft(ticket: ticket),
                    onSubmit: { draft in
                        applyTicketEdits(ticketID: session.id, draft: draft)
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ticketPartyMoveSelectedTicketUpRequested)) { _ in
            moveSelectedTicket(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ticketPartyMoveSelectedTicketDownRequested)) { _ in
            moveSelectedTicket(by: 1)
        }
        .onAppear {
            if selectedTicketID == nil {
                selectedTicketID = filteredTickets.first?.id
            }
        }
        .onChange(of: filteredTickets.map(\.id)) { _, ids in
            if let selectedTicketID, ids.contains(selectedTicketID) {
                return
            }
            self.selectedTicketID = ids.first
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

    private func applyTicketEdits(ticketID: UUID, draft: TicketDraft) {
        guard let ticket = allTickets.first(where: { $0.id == ticketID }) else {
            return
        }

        ticket.projectID = draft.projectID
        ticket.title = draft.title
        ticket.ticketDescription = draft.description
        ticket.priority = draft.priority
        ticket.severity = draft.severity
        ticket.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }

    private func moveTickets(from source: IndexSet, to destination: Int) {
        guard isManualSortEnabled else { return }
        guard let movedSourceIndex = source.first else { return }
        let movedTicketID = filteredTickets[movedSourceIndex].id

        var reorderedIDs = filteredTickets.map(\.id)
        reorderedIDs.move(fromOffsets: source, toOffset: destination)

        persistMove(ticketID: movedTicketID, reorderedIDs: reorderedIDs)
    }

    private func moveSelectedTicket(by direction: Int) {
        guard isManualSortEnabled else { return }
        guard let selectedTicketID else { return }
        guard let currentIndex = filteredTickets.firstIndex(where: { $0.id == selectedTicketID }) else { return }

        let destination: Int
        if direction < 0 {
            guard currentIndex > 0 else { return }
            destination = currentIndex - 1
        } else if direction > 0 {
            guard currentIndex < (filteredTickets.count - 1) else { return }
            destination = currentIndex + 2
        } else {
            return
        }

        var reorderedIDs = filteredTickets.map(\.id)
        reorderedIDs.move(fromOffsets: IndexSet(integer: currentIndex), toOffset: destination)
        persistMove(ticketID: selectedTicketID, reorderedIDs: reorderedIDs)
    }

    private func persistMove(ticketID: UUID, reorderedIDs: [UUID]) {
        guard let movedIndex = reorderedIDs.firstIndex(of: ticketID) else { return }
        let beforeID = movedIndex > 0 ? reorderedIDs[movedIndex - 1] : nil
        let afterID = (movedIndex + 1) < reorderedIDs.count ? reorderedIDs[movedIndex + 1] : nil

        do {
            try TicketOrdering.moveTicket(
                context: modelContext,
                ticketID: ticketID,
                projectID: project.id,
                stateID: nil,
                beforeTicketID: beforeID,
                afterTicketID: afterID
            )
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }
}

private struct ProjectWorkspaceView: View {
    let filteredTickets: [Ticket]
    @Binding var selectedTicketID: UUID?
    @Binding var selectedPriorityFilter: TicketPriority?
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String
    let selectedTicket: Ticket?
    let isManualSortEnabled: Bool
    let onMoveTickets: (IndexSet, Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ProjectFiltersPanel(
                selectedPriorityFilter: $selectedPriorityFilter,
                showHighPriorityOnly: $showHighPriorityOnly,
                searchText: $searchText
            )
            .frame(width: 220)

            Divider()

            List(selection: $selectedTicketID) {
                ForEach(filteredTickets, id: \.id) { ticket in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ticket.title)
                            .font(.headline)

                        HStack(spacing: 8) {
                            Text(ticket.displayID)
                            Text(ticket.priority.title)
                            Text(ticket.severity.title)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .moveDisabled(isManualSortEnabled == false)
                }
                .onMove(perform: onMoveTickets)
            }
            .frame(minWidth: 320, idealWidth: 380)

            Divider()

            ProjectTicketDetailPanel(ticket: selectedTicket)
                .frame(width: 280)
        }
        .overlay(alignment: .bottomLeading) {
            if isManualSortEnabled == false {
                Text("Clear filters and search to manually reorder tickets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }
}

private struct ProjectFiltersPanel: View {
    @Binding var selectedPriorityFilter: TicketPriority?
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters")
                .font(.headline)

            Picker("Priority", selection: $selectedPriorityFilter) {
                Text("All Priorities").tag(TicketPriority?.none)
                ForEach(TicketPriority.allCases, id: \.self) { priority in
                    Text(priority.title).tag(Optional(priority))
                }
            }
            .pickerStyle(.menu)

            Toggle("High/Urgent Only", isOn: $showHighPriorityOnly)

            TextField("Search tickets", text: $searchText)

            Spacer()
        }
        .padding(12)
    }
}

private struct ProjectTicketDetailPanel: View {
    @Environment(\.modelContext) private var modelContext
    let ticket: Ticket?

    var body: some View {
        Group {
            if let ticket {
                Form {
                    Section("Ticket") {
                        LabeledContent("ID", value: ticket.displayID)
                    }

                    Section("Details") {
                        Picker("Priority", selection: priorityBinding(for: ticket)) {
                            ForEach(TicketPriority.allCases, id: \.self) { priority in
                                Text(priority.title).tag(priority)
                            }
                        }

                        Picker("Severity", selection: severityBinding(for: ticket)) {
                            ForEach(TicketSeverity.allCases, id: \.self) { severity in
                                Text(severity.title).tag(severity)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Select a Ticket", systemImage: "doc.text")
            }
        }
    }

    private func priorityBinding(for ticket: Ticket) -> Binding<TicketPriority> {
        Binding(
            get: { ticket.priority },
            set: { newPriority in
                ticket.priority = newPriority
                persist(ticket: ticket)
            }
        )
    }

    private func severityBinding(for ticket: Ticket) -> Binding<TicketSeverity> {
        Binding(
            get: { ticket.severity },
            set: { newSeverity in
                ticket.severity = newSeverity
                persist(ticket: ticket)
            }
        )
    }

    private func persist(ticket: Ticket) {
        ticket.updatedAt = .now
        do {
            try modelContext.save()
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }
}

private struct TicketEditSession: Identifiable {
    let id: UUID
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
        let schema = Schema([Project.self, Ticket.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create preview container: \(error)")
        }
    }()

    static let project: Project = {
        let source = SampleData.projects.first ?? StubProject(
            id: UUID(),
            name: "Project",
            statusText: "Status",
            summary: "Summary"
        )

        let project = Project(
            id: source.id,
            name: source.name,
            statusText: source.statusText,
            summary: source.summary
        )

        let context = container.mainContext
        context.insert(project)

        let previewTickets = SampleData.tickets(for: project).enumerated().map { index, ticket in
            Ticket(
                ticketNumber: index + 1,
                displayID: "TT-\(index + 1)",
                projectID: project.id,
                orderKey: Int64(index + 1) * TicketOrdering.keyStep,
                title: ticket.title,
                description: ticket.latestNote,
                priority: ticket.priority.ticketPriority,
                severity: ticket.priority.ticketSeverity
            )
        }

        previewTickets.forEach(context.insert)

        do {
            try context.save()
        } catch {
            // Preview-only context; ignore save failures.
        }

        return project
    }()
}
