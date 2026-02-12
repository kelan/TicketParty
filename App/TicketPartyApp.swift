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

            CommandMenu("Tickets") {
                Button("Edit Selected Ticket") {
                    NotificationCenter.default.post(name: .ticketPartyEditSelectedTicketRequested, object: nil)
                }
                .keyboardShortcut("e")

                Button("Move Selected Ticket to Top of Backlog") {
                    NotificationCenter.default.post(name: .ticketPartyMoveSelectedTicketToTopRequested, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control, .option])

                Button("Move Selected Ticket Up") {
                    NotificationCenter.default.post(name: .ticketPartyMoveSelectedTicketUpRequested, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])

                Button("Move Selected Ticket Down") {
                    NotificationCenter.default.post(name: .ticketPartyMoveSelectedTicketDownRequested, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])

                Divider()

                Button("Toggle Add to Top of Backlog") {
                    NotificationCenter.default.post(name: .ticketPartyToggleAddToTopOfBacklogRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
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
