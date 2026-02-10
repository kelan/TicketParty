//
//  ContentView.swift
//  TicketParty
//
//  Created by Kelan Champagne on 2/9/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Task.ticketNumber)]) private var tasks: [Task]

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(tasks) { task in
                    NavigationLink {
                        Text(task.title)
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

#Preview {
    ContentView()
        .modelContainer(for: Task.self, inMemory: true)
}
