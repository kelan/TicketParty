//
//  TicketPartyApp.swift
//  TicketParty
//
//  Created by Kelan Champagne on 2/9/26.
//

import Foundation
import SwiftData
import SwiftUI
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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Ticket") {
                    NotificationCenter.default.post(name: .ticketPartyNewTicketRequested, object: nil)
                }
                .keyboardShortcut("n")
            }
        }

        #if os(macOS)
            Settings {
                TicketPartySettingsView()
            }
            .modelContainer(sharedModelContainer)
        #endif
    }
}
