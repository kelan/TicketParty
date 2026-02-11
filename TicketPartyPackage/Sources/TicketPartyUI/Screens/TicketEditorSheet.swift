import SwiftUI
import TicketPartyDataStore
import TicketPartyModels

struct TicketEditorSheet: View {
    let title: String
    let submitLabel: String
    let projects: [Project]
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
        initialDraft: TicketDraft,
        onSubmit: @escaping (TicketDraft) -> Void
    ) {
        self.title = title
        self.submitLabel = submitLabel
        self.projects = projects
        self.initialDraft = initialDraft
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ticket") {
                    TextField("Title", text: $draft.title)
                        .focused($focusedField, equals: .title)

                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(4 ... 8)
                        .focused($focusedField, equals: .description)
                }

                Section("Details") {
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
