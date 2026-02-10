//
//  TicketPartyApp.swift
//  TicketParty
//
//  Created by Kelan Champagne on 2/9/26.
//

import SwiftUI
import SwiftData

@main
struct TicketPartyApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Task.self,
            Note.self,
            Comment.self,
            Workflow.self,
            WorkflowState.self,
            WorkflowTransition.self,
            Assignment.self,
            Agent.self,
            TaskEvent.self,
            SessionMarker.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
