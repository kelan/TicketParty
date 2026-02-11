import SwiftData
import SwiftUI
import TicketPartyDataStore
import TicketPartyModels
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CodexViewModel.self) private var codexViewModel
    @Query(sort: [SortDescriptor(\Ticket.orderKey, order: .forward), SortDescriptor(\Ticket.createdAt, order: .forward)]) private var allTickets: [Ticket]

    @Bindable var project: Project
    let onSelectedTicketChange: (UUID?) -> Void
    let onRequestNewTicket: (UUID?) -> Void

    @State private var selectedTicketID: UUID?
    @State private var selectionAnchorTicketID: UUID?
    @State private var selectedSizeFilter: TicketSize?
    @State private var selectedStateScope: TicketStateScope = .overview
    @State private var searchText = ""
    @State private var isPresentingEditProject = false
    @State private var ticketEditSession: TicketEditSession?
    private let overviewDoneLimit = 5
    private let isPreview: Bool

    init(
        project: Project,
        initialSelectedTicketID: UUID? = nil,
        onSelectedTicketChange: @escaping (UUID?) -> Void = { _ in },
        onRequestNewTicket: @escaping (UUID?) -> Void = { _ in },
        isPreview: Bool = false
    ) {
        self.project = project
        self.onSelectedTicketChange = onSelectedTicketChange
        self.onRequestNewTicket = onRequestNewTicket
        self.isPreview = isPreview
        _selectedTicketID = State(initialValue: initialSelectedTicketID)
    }

    private var tickets: [Ticket] {
        allTickets.filter { ticket in
            ticket.archivedAt == nil &&
                ticket.closedAt == nil &&
                ticket.projectID == project.id
        }
    }

    private var isSoftFilterActive: Bool {
        selectedSizeFilter != nil || searchText.isEmpty == false
    }

    private var scopedAndFilteredTickets: [Ticket] {
        let scopedTickets = tickets.filter { ticket in
            selectedStateScope.matches(ticket.quickStatus)
        }

        return scopedTickets.filter { ticket in
            let sizeMatches = selectedSizeFilter == nil || ticket.size == selectedSizeFilter
            let searchMatches = searchText.isEmpty || ticket.title.localizedCaseInsensitiveContains(searchText)
            return sizeMatches && searchMatches
        }
    }

    private var visibleTickets: [Ticket] {
        visibleRecentDoneTickets +
            visibleInProgressTickets +
            visibleBacklogTickets +
            visibleOtherTickets
    }

    private var visibleInProgressTickets: [Ticket] {
        guard selectedStateScope != .allDone else { return [] }
        return inProgressTickets(in: scopedAndFilteredTickets)
    }

    private var visibleRecentDoneTickets: [Ticket] {
        switch selectedStateScope {
        case .overview:
            return doneTickets(in: scopedAndFilteredTickets, limit: overviewDoneLimit)
        case .allDone, .everything:
            return doneTickets(in: scopedAndFilteredTickets, limit: nil)
        }
    }

    private var visibleBacklogTickets: [Ticket] {
        guard selectedStateScope != .allDone else { return [] }
        return backlogTickets(in: scopedAndFilteredTickets)
    }

    private var visibleOtherTickets: [Ticket] {
        guard selectedStateScope != .allDone else { return [] }
        return otherTickets(in: scopedAndFilteredTickets)
    }

    private var isBacklogReorderingEnabled: Bool {
        isSoftFilterActive == false
    }

    private var backlogStateIDs: Set<UUID> {
        [
            TicketQuickStatus.backlog.stateID,
            TicketQuickStatus.needsThinking.stateID,
            TicketQuickStatus.readyToImplement.stateID,
            TicketQuickStatus.blocked.stateID,
        ]
    }

    private var selectedTicket: Ticket? {
        guard let selectedTicketID else { return nil }
        return tickets.first { $0.id == selectedTicketID }
    }

    private var availableProjects: [Project] {
        [project]
    }

    private var canStartRunLoop: Bool {
        switch codexViewModel.loopState(for: project.id) {
        case .idle, .completed:
            return true
        case .preparingQueue, .running, .paused, .failed, .cancelling:
            return false
        }
    }

    var body: some View {
        ProjectWorkspaceView(
            project: project,
            inProgressTickets: visibleInProgressTickets,
            recentDoneTickets: visibleRecentDoneTickets,
            backlogTickets: visibleBacklogTickets,
            otherTickets: visibleOtherTickets,
            selectedTicketID: $selectedTicketID,
            selectedSizeFilter: $selectedSizeFilter,
            selectedStateScope: $selectedStateScope,
            doneSectionTitle: selectedStateScope.doneSectionTitle,
            searchText: $searchText,
            selectedTicket: selectedTicket,
            isBacklogReorderingEnabled: isBacklogReorderingEnabled,
            onMoveBacklogTickets: moveBacklogTickets,
            onOpenTicketForEditing: openTicketForEditing,
            isPreview: isPreview
        )
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await codexViewModel.startLoop(project: project, tickets: allTickets)
                    }
                } label: {
                    Image(systemName: "play.circle")
                }
                .help("Start Run Loop")
                .disabled(canStartRunLoop == false)

                Button {
                    onRequestNewTicket(project.id)
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Ticket")

                if let selectedTicket {
                    Button {
                        openTicketForEditing(selectedTicket.id)
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
            guard isPreview == false else { return }
            moveSelectedTicket(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ticketPartyMoveSelectedTicketDownRequested)) { _ in
            guard isPreview == false else { return }
            moveSelectedTicket(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ticketPartyEditSelectedTicketRequested)) { _ in
            guard isPreview == false else { return }
            requestEditSelectedTicket()
        }
        .onAppear {
            guard isPreview == false else { return }
            if selectedTicketID == nil {
                selectedTicketID = visibleTickets.first?.id
            }
            if selectionAnchorTicketID == nil {
                selectionAnchorTicketID = selectedTicketID
            }
        }
        .onChange(of: selectedTicketID) { _, newID in
            guard isPreview == false else { return }
            onSelectedTicketChange(newID)
            guard let newID else { return }
            selectionAnchorTicketID = newID
        }
        .onChange(of: visibleTickets.map(\.id)) { _, ids in
            guard isPreview == false else { return }
            guard ids.isEmpty == false else {
                if isSoftFilterActive {
                    selectedTicketID = nil
                }
                return
            }

            if let selectedTicketID, ids.contains(selectedTicketID) {
                return
            }

            if isSoftFilterActive {
                self.selectedTicketID = ids.first
                return
            }

            if let anchorID = selectionAnchorTicketID, ids.contains(anchorID) {
                selectedTicketID = anchorID
                return
            }

            selectedTicketID = ids.first
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
        openTicketForEditing(selectedTicket.id)
    }

    private func openTicketForEditing(_ ticketID: UUID) {
        selectedTicketID = ticketID
        ticketEditSession = TicketEditSession(id: ticketID)
    }

    private func applyTicketEdits(ticketID: UUID, draft: TicketDraft) {
        guard let ticket = allTickets.first(where: { $0.id == ticketID }) else {
            return
        }

        ticket.projectID = draft.projectID
        ticket.title = draft.title
        ticket.ticketDescription = draft.description
        ticket.size = draft.size
        ticket.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }

    private func moveBacklogTickets(from source: IndexSet, to destination: Int) {
        guard isBacklogReorderingEnabled else { return }
        guard let movedSourceIndex = source.first else { return }
        let movedTicketID = visibleBacklogTickets[movedSourceIndex].id

        var reorderedIDs = visibleBacklogTickets.map(\.id)
        reorderedIDs.move(fromOffsets: source, toOffset: destination)

        persistBacklogMove(ticketID: movedTicketID, reorderedIDs: reorderedIDs)
    }

    private func moveSelectedTicket(by direction: Int) {
        guard isBacklogReorderingEnabled else { return }
        guard let selectedTicketID else { return }
        guard let currentIndex = visibleBacklogTickets.firstIndex(where: { $0.id == selectedTicketID }) else { return }

        let destination: Int
        if direction < 0 {
            guard currentIndex > 0 else { return }
            destination = currentIndex - 1
        } else if direction > 0 {
            guard currentIndex < (visibleBacklogTickets.count - 1) else { return }
            destination = currentIndex + 2
        } else {
            return
        }

        var reorderedIDs = visibleBacklogTickets.map(\.id)
        reorderedIDs.move(fromOffsets: IndexSet(integer: currentIndex), toOffset: destination)
        persistBacklogMove(ticketID: selectedTicketID, reorderedIDs: reorderedIDs)
    }

    private func persistBacklogMove(ticketID: UUID, reorderedIDs: [UUID]) {
        guard let movedIndex = reorderedIDs.firstIndex(of: ticketID) else { return }
        let beforeID = movedIndex > 0 ? reorderedIDs[movedIndex - 1] : nil
        let afterID = (movedIndex + 1) < reorderedIDs.count ? reorderedIDs[movedIndex + 1] : nil

        do {
            try TicketOrdering.moveTicket(
                context: modelContext,
                ticketID: ticketID,
                projectID: project.id,
                scopeStateIDs: backlogStateIDs,
                beforeTicketID: beforeID,
                afterTicketID: afterID
            )
        } catch {
            // Keep UI flow simple for now; we'll add user-visible error handling later.
        }
    }

    private func inProgressTickets(in tickets: [Ticket]) -> [Ticket] {
        tickets
            .filter { $0.quickStatus == .inProgress }
    }

    private func doneTickets(in tickets: [Ticket], limit: Int?) -> [Ticket] {
        let sortedDoneTickets = tickets
            .filter { $0.quickStatus.isDone }
            .sorted(by: sortByMostRecentlyUpdated)

        if let limit {
            return Array(sortedDoneTickets.prefix(limit).reversed())
        }

        return Array(sortedDoneTickets.reversed())
    }

    private func backlogTickets(in tickets: [Ticket]) -> [Ticket] {
        tickets
            .filter { $0.quickStatus.isBacklogSortable }
            .sorted(by: sortByOrderKeyAndCreatedAt)
    }

    private func otherTickets(in tickets: [Ticket]) -> [Ticket] {
        tickets
            .filter { $0.quickStatus != .inProgress && $0.quickStatus.isDone == false && $0.quickStatus.isBacklogSortable == false }
            .sorted(by: sortByOrderKeyAndCreatedAt)
    }

    private func sortByMostRecentlyUpdated(_ lhs: Ticket, _ rhs: Ticket) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private func sortByOrderKeyAndCreatedAt(_ lhs: Ticket, _ rhs: Ticket) -> Bool {
        if lhs.orderKey == rhs.orderKey {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.orderKey < rhs.orderKey
    }
}

private struct ProjectWorkspaceView: View {
    @Environment(CodexViewModel.self) private var codexViewModel
    let project: Project
    let inProgressTickets: [Ticket]
    let recentDoneTickets: [Ticket]
    let backlogTickets: [Ticket]
    let otherTickets: [Ticket]
    @Binding var selectedTicketID: UUID?
    @Binding var selectedSizeFilter: TicketSize?
    @Binding var selectedStateScope: TicketStateScope
    let doneSectionTitle: String
    @Binding var searchText: String
    let selectedTicket: Ticket?
    let isBacklogReorderingEnabled: Bool
    let onMoveBacklogTickets: (IndexSet, Int) -> Void
    let onOpenTicketForEditing: (UUID) -> Void
    let isPreview: Bool

    var body: some View {
        HStack(spacing: 0) {
            ProjectFiltersPanel(
                selectedSizeFilter: $selectedSizeFilter,
                selectedStateScope: $selectedStateScope,
                searchText: $searchText
            )
            .frame(width: 220)

            Divider()

            List(selection: isPreview ? .constant(nil) : $selectedTicketID) {
                if recentDoneTickets.isEmpty == false {
                    Section {
                        ForEach(recentDoneTickets, id: \.id) { ticket in
                            ticketRow(ticket)
                                .foregroundStyle(.secondary)
                                .tag(ticket.id)
                        }
                    } header: {
                        Text(doneSectionTitle)
                            .font(.title2)
                    }
                }

                if inProgressTickets.isEmpty == false {
                    Section {
                        ForEach(inProgressTickets, id: \.id) { ticket in
                            ticketRow(ticket)
                                .tag(ticket.id)
                        }
                    } header: {
                        Text("In Progress")
                            .font(.title2)
                    }
                }

                if backlogTickets.isEmpty == false {
                    Section {
                        ForEach(backlogTickets, id: \.id) { ticket in
                            ticketRow(ticket)
                                .moveDisabled(isBacklogReorderingEnabled == false)
                                .tag(ticket.id)
                        }
                        .onMove(perform: onMoveBacklogTickets)
                    } header: {
                        Text("Backlog")
                            .font(.title2)
                    }
                }

                if otherTickets.isEmpty == false {
                    Section("Other") {
                        ForEach(otherTickets, id: \.id) { ticket in
                            ticketRow(ticket)
                                .tag(ticket.id)
                        }
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380)

            Divider()

            ProjectTicketDetailPanel(project: project, ticket: selectedTicket)
                .frame(width: 280)
        }
        .overlay(alignment: .bottomLeading) {
            if isBacklogReorderingEnabled == false {
                Text("Backlog reordering is disabled while size/search filters are active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private func ticketRow(_ ticket: Ticket) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.title)
                    .font(.headline)
                    .fontWeight(.medium)

                if ticket.ticketDescription.isEmpty == false && !ticket.quickStatus.isDone {
                    Text(ticket.ticketDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                if let doneDateStamp = doneDateStamp(for: ticket) {
                    Text(doneDateStamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(ticket.displayID)
                    Text(ticket.size.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if codexViewModel.ticketIsSending[ticket.id] == true {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityLabel("Running with agent")
            }

            TicketStatusBadge(status: ticket.quickStatus)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isPreview == false else { return }
            selectedTicketID = ticket.id
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    guard isPreview == false else { return }
                    onOpenTicketForEditing(ticket.id)
                }
        )
    }

    private func doneDateStamp(for ticket: Ticket) -> String? {
        guard ticket.quickStatus.isDone else { return nil }
        let doneDate = ticket.doneAt ?? ticket.updatedAt
        return "Done \(doneDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

private enum TicketStateScope: String, CaseIterable, Identifiable {
    case overview
    case allDone
    case everything

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .allDone:
            return "All Done"
        case .everything:
            return "Everything"
        }
    }

    var doneSectionTitle: String {
        switch self {
        case .overview:
            return "Recently Done"
        case .allDone:
            return "All Done"
        case .everything:
            return "Done"
        }
    }

    func matches(_ status: TicketQuickStatus) -> Bool {
        switch self {
        case .overview, .everything:
            return true
        case .allDone:
            return status.isDone
        }
    }
}

private struct ProjectFiltersPanel: View {
    @Binding var selectedSizeFilter: TicketSize?
    @Binding var selectedStateScope: TicketStateScope
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
            .pickerStyle(.segmented)

            Picker("Size", selection: $selectedSizeFilter) {
                Text("All Sizes").tag(TicketSize?.none)
                ForEach(TicketSize.allCases, id: \.self) { size in
                    Text(size.title).tag(Optional(size))
                }
            }
            .pickerStyle(.menu)

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
                        Picker("Size", selection: sizeBinding(for: ticket)) {
                            ForEach(TicketSize.allCases, id: \.self) { size in
                                Text(size.title).tag(size)
                            }
                        }
                    }

                    Section("Codex") {
                        let isSending = codexViewModel.ticketIsSending[ticket.id] == true
                        HStack(spacing: 8) {
                            Button("Send to Codex") {
                                if ticket.quickStatus != .inProgress {
                                    ticket.quickStatus = .inProgress
                                    persist(ticket: ticket)
                                }
                                Task {
                                    await codexViewModel.send(ticket: ticket, project: project)
                                }
                            }
                            .disabled(isSending)

                            if isSending {
                                Button("Stop") {
                                    Task {
                                        await codexViewModel.stop(ticket: ticket, project: project)
                                    }
                                }
                                .tint(.red)

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
                            let outputSnapshot = codexViewModel.outputSnapshot(for: ticket.id, maxBytes: 200_000)
                            Text(outputSnapshot.text.isEmpty ? "No output yet." : outputSnapshot.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                            if outputSnapshot.isTruncated {
                                Text("Showing latest output segment.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        .frame(minHeight: 180)
                    }
                }
            } else {
                ContentUnavailableView("Select a Ticket", systemImage: "doc.text")
            }
        }
    }

    private func sizeBinding(for ticket: Ticket) -> Binding<TicketSize> {
        Binding(
            get: { ticket.size },
            set: { newSize in
                ticket.size = newSize
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

    var isBacklogSortable: Bool {
        self == .backlog ||
            self == .needsThinking ||
            self == .readyToImplement ||
            self == .blocked
    }

    var tintColor: Color {
        switch self {
        case .backlog:
            return .gray
        case .needsThinking:
            return .purple
        case .readyToImplement:
            return .cyan
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
    ProjectDetailView(project: ProjectPreviewData.project, isPreview: true)
        .modelContainer(ProjectPreviewData.container)
        .environment(ProjectPreviewData.codexViewModel)
}

@MainActor
private enum ProjectPreviewData {
    static let codexViewModel = CodexViewModel(
        manager: CodexManager(resumeSubscriptionsOnInit: false),
        startBackgroundTasks: false
    )

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
                size: ticket.size.ticketSize,
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
