import SwiftUI
import TicketPartyDataStore
import TicketPartyModels

struct TicketEditorSheet: View {
    let title: String
    let submitLabel: String
    let projects: [Project]
    let showsAddToTopOfBacklogOption: Bool
    private let initialDraft: TicketDraft
    let onSubmit: (TicketDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TicketDraft
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case description
    }

    init(
        title: String,
        submitLabel: String,
        projects: [Project],
        showsAddToTopOfBacklogOption: Bool = false,
        initialDraft: TicketDraft,
        onSubmit: @escaping (TicketDraft) -> Void
    ) {
        self.title = title
        self.submitLabel = submitLabel
        self.projects = projects
        self.showsAddToTopOfBacklogOption = showsAddToTopOfBacklogOption
        self.initialDraft = initialDraft
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $draft.title, axis: .vertical)
                    .lineLimit(1...)
                    .focused($focusedField, equals: .title)

                TextField("Description", text: $draft.description, axis: .vertical)
                    .lineLimit(4 ... 8)
                    .focused($focusedField, equals: .description)

                Picker("Project", selection: $draft.projectID) {
                    Text("Select Project").tag(UUID?.none)
                    ForEach(projects, id: \.id) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }

                Picker("Size", selection: $draft.size) {
                    ForEach(TicketSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
            }
            .padding(16)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .confirmationAction) {
                    if showsAddToTopOfBacklogOption {
                        Toggle("Add to top of backlog", isOn: $draft.addToTopOfBacklog)
                        #if os(macOS)
                            .toggleStyle(.checkbox)
                        #endif
                            .help("Toggle Add to top of backlog (\u{2318}\u{21E7}T)")
                    }

                    Button(submitLabel) {
                        onSubmit(draft.normalized)
                        dismiss()
                    }
                    .disabled(draft.canSubmit == false)
                }
            }
        }
        .onAppear {
            draft = initialDraft
            applyDefaultProjectSelection()
            focusedField = .title
        }
        .onChange(of: projects.map(\.id)) { _, _ in
            applyDefaultProjectSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ticketPartyToggleAddToTopOfBacklogRequested)) { _ in
            guard showsAddToTopOfBacklogOption else { return }
            draft.addToTopOfBacklog.toggle()
        }
        #if os(macOS)
        .presentationSizing(.fitted)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640)
        #else
        .frame(minWidth: 560, minHeight: 380)
        #endif
    }

    private func applyDefaultProjectSelection() {
        let projectIDs = Set(projects.map(\.id))

        if let currentProjectID = draft.projectID, projectIDs.contains(currentProjectID) {
            return
        }

        draft.projectID = projects.first?.id
    }
}

#Preview("Ticket Editor Sheet") {
    let sampleProjects = [
        Project(name: "App Redesign", statusText: "Designing the new dashboard"),
        Project(name: "Infra", statusText: "Scaling ticket ingestion"),
    ]

    TicketEditorSheet(
        title: "New Ticket",
        submitLabel: "Create",
        projects: sampleProjects,
        initialDraft: TicketDraft(
            projectID: sampleProjects.first?.id,
            title: "Tidy the settings screen",
            description: "Group the toggles and update help copy.",
            size: .requiresThinking
        ),
        onSubmit: { _ in }
    )
}
