//
//  ContentView.swift
//  TicketParty
//
//  Created by Kelan Champagne on 2/9/26.
//

import SwiftUI
import SwiftData

public struct TicketPartyRootView: View {
    @State private var selectedTab: MainTab = .tasks

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            TasksTabView()
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }
                .tag(MainTab.tasks)

            ActivityTabView()
                .tabItem {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                }
                .tag(MainTab.activity)

            SettingsTabView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(MainTab.settings)
        }
    }
}

private enum MainTab {
    case tasks
    case activity
    case settings
}

private struct TasksTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Task.ticketNumber)]) private var tasks: [Task]

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(tasks) { task in
                    NavigationLink {
                        TaskDetailView(task: task)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.displayID)
                                .font(.headline)
                            Text(task.title)
                                .font(.subheadline)
                            Text(task.priority.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteTasks)
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
#endif
                ToolbarItem {
                    Button(action: addTask) {
                        Label("Add Task", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select a task")
        }
    }

    private func addTask() {
        withAnimation {
            let nextTicketNumber = (tasks.last?.ticketNumber ?? 0) + 1
            let newTask = Task(
                ticketNumber: nextTicketNumber,
                displayID: "TT-\(nextTicketNumber)",
                title: "New Task \(nextTicketNumber)"
            )
            modelContext.insert(newTask)
            try? modelContext.save()
        }
    }

    private func deleteTasks(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(tasks[index])
            }
            try? modelContext.save()
        }
    }
}

private struct ActivityTabView: View {
    @Query(sort: [SortDescriptor(\Task.updatedAt, order: .reverse)]) private var recentlyUpdatedTasks: [Task]

    var body: some View {
        NavigationStack {
            Group {
                if recentlyUpdatedTasks.isEmpty {
                    Text("No task activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List(Array(recentlyUpdatedTasks.prefix(30))) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.displayID)
                                .font(.headline)
                            Text(task.title)
                                .font(.subheadline)
                            Text(task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Activity")
        }
    }
}

private struct SettingsTabView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    LabeledContent("Theme", value: "System")
                    LabeledContent("Notifications", value: "Enabled")
                }

                Section("Sync") {
                    LabeledContent("Provider", value: "Local")
                    LabeledContent("Last Sync", value: "Never")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    TicketPartyRootView()
        .modelContainer(for: Task.self, inMemory: true)
}

private struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var task: Task
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("Task Details") {
                TextField("Title", text: $task.title)

                TextField("Description", text: $task.taskDescription, axis: .vertical)
                    .lineLimit(4...8)

                Picker("Priority", selection: $task.priority) {
                    ForEach(TaskPriority.allCases, id: \.self) { priority in
                        Text(priority.rawValue.capitalized).tag(priority)
                    }
                }

                Picker("Severity", selection: $task.severity) {
                    ForEach(TaskSeverity.allCases, id: \.self) { severity in
                        Text(severity.rawValue.capitalized).tag(severity)
                    }
                }
            }

            Section("Identifiers") {
                LabeledContent("Display ID", value: task.displayID)
                LabeledContent("Ticket Number", value: String(task.ticketNumber))
                LabeledContent("Task ID", value: task.id.uuidString)
            }

            Section("Lifecycle") {
                LabeledContent("Workflow ID", value: task.workflowID?.uuidString ?? "—")
                LabeledContent("State ID", value: task.stateID?.uuidString ?? "—")
                LabeledContent("Assignee ID", value: task.assigneeID?.uuidString ?? "—")
                LabeledContent("Created", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Updated", value: task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Closed", value: task.closedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                LabeledContent("Archived", value: task.archivedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            }
        }
        .navigationTitle(task.displayID)
        .toolbar {
            Button("Save", action: saveChanges)
        }
        .alert("Save Failed", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { shouldShow in
                if shouldShow == false {
                    saveError = nil
                }
            }
        )
    }

    private func saveChanges() {
        task.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
