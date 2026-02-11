import SwiftData
import SwiftUI
import TicketPartyDataStore
import TicketPartyModels
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Ticket.orderKey, order: .forward), SortDescriptor(\Ticket.createdAt, order: .forward)]) private var allTickets: [Ticket]

    @Bindable var project: Project
    let onRequestNewTicket: (UUID?) -> Void

    @State private var selectedTicketID: UUID?
    @State private var selectedPriorityFilter: TicketPriority?
    @State private var selectedStateScope: TicketStateScope = .remaining
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
            let stateMatches = selectedStateScope.matches(ticket.quickStatus)
            let highPriorityMatches = showHighPriorityOnly == false || ticket.priority == .high || ticket.priority == .urgent
            let searchMatches = searchText.isEmpty || ticket.title.localizedCaseInsensitiveContains(searchText)
            return priorityMatches && stateMatches && highPriorityMatches && searchMatches
        }
    }

    private var isManualSortEnabled: Bool {
        selectedPriorityFilter == nil &&
            selectedStateScope == .allStates &&
            showHighPriorityOnly == false &&
            searchText.isEmpty
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
            project: project,
            filteredTickets: filteredTickets,
            selectedTicketID: $selectedTicketID,
            selectedPriorityFilter: $selectedPriorityFilter,
            selectedStateScope: $selectedStateScope,
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
            }

            ToolbarItem(placement: .navigation) {
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
                    summary: project.summary,
                    workingDirectory: project.workingDirectory ?? ""
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
        .onReceive(NotificationCenter.default.publisher(for: .ticketPartyEditSelectedTicketRequested)) { _ in
            requestEditSelectedTicket()
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
        project.workingDirectory = draft.normalizedWorkingDirectory
        project.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }

    private func requestEditSelectedTicket() {
        guard let selectedTicket else { return }
        ticketEditSession = TicketEditSession(id: selectedTicket.id)
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
    let project: Project
    let filteredTickets: [Ticket]
    @Binding var selectedTicketID: UUID?
    @Binding var selectedPriorityFilter: TicketPriority?
    @Binding var selectedStateScope: TicketStateScope
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String
    let selectedTicket: Ticket?
    let isManualSortEnabled: Bool
    let onMoveTickets: (IndexSet, Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ProjectFiltersPanel(
                selectedPriorityFilter: $selectedPriorityFilter,
                selectedStateScope: $selectedStateScope,
                showHighPriorityOnly: $showHighPriorityOnly,
                searchText: $searchText
            )
            .frame(width: 220)

            Divider()

            List(selection: $selectedTicketID) {
                ForEach(filteredTickets, id: \.id) { ticket in
                    HStack(alignment: .top, spacing: 8) {
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

                        Spacer(minLength: 0)

                        TicketStatusBadge(status: ticket.quickStatus)
                    }
                    .padding(.vertical, 2)
                    .moveDisabled(isManualSortEnabled == false)
                }
                .onMove(perform: onMoveTickets)
            }
            .frame(minWidth: 320, idealWidth: 380)

            Divider()

            ProjectTicketDetailPanel(project: project, ticket: selectedTicket)
                .frame(width: 280)
        }
        .overlay(alignment: .bottomLeading) {
            if isManualSortEnabled == false {
                Text("Clear filters, state scope, and search to manually reorder tickets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }
}

private enum TicketStateScope: String, CaseIterable, Identifiable {
    case allStates
    case remaining
    case available

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .allStates:
            return "All States"
        case .remaining:
            return "Remaining"
        case .available:
            return "Available"
        }
    }

    func matches(_ status: TicketQuickStatus) -> Bool {
        switch self {
        case .allStates:
            return true
        case .remaining:
            return status != .done && status != .skipped && status != .duplicate
        case .available:
            return status == .backlog || status == .inProgress || status == .review
        }
    }
}

private struct ProjectFiltersPanel: View {
    @Binding var selectedPriorityFilter: TicketPriority?
    @Binding var selectedStateScope: TicketStateScope
    @Binding var showHighPriorityOnly: Bool
    @Binding var searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters")
                .font(.headline)

            Picker("States", selection: $selectedStateScope) {
                ForEach(TicketStateScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.menu)

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
    @Environment(CodexViewModel.self) private var codexViewModel
    let project: Project
    let ticket: Ticket?

    var body: some View {
        Group {
            if let ticket {
                Form {
                    Section("Ticket") {
                        LabeledContent("ID", value: ticket.displayID)
                    }

                    Section("Status") {
                        LabeledContent("Current", value: ticket.quickStatus.title)

                        TicketStatusQuickActions(currentStatus: ticket.quickStatus) { status in
                            guard status != ticket.quickStatus else { return }
                            ticket.quickStatus = status
                            persist(ticket: ticket)
                        }
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

                    Section("Codex") {
                        let isSending = codexViewModel.ticketIsSending[ticket.id] == true
                        HStack(spacing: 8) {
                            Button("Send to Codex") {
                                Task {
                                    await codexViewModel.send(ticket: ticket, project: project)
                                }
                            }
                            .disabled(isSending)

                            if isSending {
                                ProgressView("Sending...")
                                    .controlSize(.small)
                                    .font(.caption)
                            } else if let error = codexViewModel.ticketErrors[ticket.id], error.isEmpty == false {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                            }
                        }

                        if let error = codexViewModel.ticketErrors[ticket.id], error.isEmpty == false {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        ScrollView {
                            let output = codexViewModel.output(for: ticket.id)
                            Text(output.isEmpty ? "No output yet." : output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(minHeight: 180)
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

private struct TicketStatusQuickActions: View {
    let currentStatus: TicketQuickStatus
    let onSelect: (TicketQuickStatus) -> Void

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(TicketQuickStatus.allCases) { status in
                Button(status.title) {
                    onSelect(status)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(status == currentStatus ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .foregroundStyle(status.tintColor)
                .background(status.tintColor.opacity(status == currentStatus ? 0.24 : 0.12), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(status.tintColor.opacity(status == currentStatus ? 0.9 : 0.5), lineWidth: 1)
                }
                .contentShape(Capsule())
                .controlSize(.small)
            }
        }
    }
}

private struct TicketStatusBadge: View {
    let status: TicketQuickStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(status.tintColor)
            .background(status.tintColor.opacity(0.24), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(status.tintColor.opacity(0.9), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: true)
    }
}

private extension TicketQuickStatus {
    var tintColor: Color {
        switch self {
        case .backlog:
            return .gray
        case .inProgress:
            return .blue
        case .blocked:
            return .orange
        case .review:
            return .indigo
        case .done:
            return .green
        case .skipped:
            return .brown
        case .duplicate:
            return .mint
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
    @State private var isPresentingWorkingDirectoryPicker = false

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

                Section("Codex") {
                    HStack(spacing: 8) {
                        TextField("Working Directory", text: $draft.workingDirectory)
                        Button {
                            isPresentingWorkingDirectoryPicker = true
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Choose Working Directory")
                    }
                    Text("Required to run Codex for this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .fileImporter(
                isPresented: $isPresentingWorkingDirectoryPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else {
                    return
                }
                draft.workingDirectory = url.path(percentEncoded: false)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

#Preview {
    ProjectDetailView(project: ProjectPreviewData.project)
        .modelContainer(ProjectPreviewData.container)
        .environment(CodexViewModel())
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
                severity: ticket.priority.ticketSeverity,
                stateID: ticket.state.ticketQuickStatus.stateID
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
