import Foundation
import SwiftData

public enum TicketPartyPersistence {
    public static func makeSharedContainer() throws -> ModelContainer {
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

        let storeURL = try sharedStoreURL()
        let configuration = ModelConfiguration(
            "TicketParty",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func sharedStoreURL() throws -> URL {
        let appSupportURL = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        let directoryURL = appSupportURL.appendingPathComponent("TicketParty", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("TicketParty.store")
    }
}
