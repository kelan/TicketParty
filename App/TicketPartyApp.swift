//
//  TicketPartyApp.swift
//  TicketParty
//
//  Created by Kelan Champagne on 2/9/26.
//

import SwiftUI
import SwiftData
import TicketPartyDataStore
import TicketPartyUI

@main
struct TicketPartyApp: App {
    var sharedModelContainer: ModelContainer = {
        do {
            return try TicketPartyPersistence.makeSharedContainer()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            TicketPartyRootView()
        }
        .modelContainer(sharedModelContainer)

#if os(macOS)
        Settings {
            TicketPartySettingsView()
        }
        .modelContainer(sharedModelContainer)
#endif
    }
}
