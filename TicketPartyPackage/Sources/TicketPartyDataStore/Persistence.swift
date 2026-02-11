import Foundation
import SQLite3
import SwiftData

public enum TicketPartyPersistence {
    public static func makeSharedContainer() throws -> ModelContainer {
        let schema = Schema([
            Project.self,
            Ticket.self,
            Note.self,
            Comment.self,
            Workflow.self,
            WorkflowState.self,
            WorkflowTransition.self,
            Assignment.self,
            Agent.self,
            TicketEvent.self,
            SessionMarker.self,
        ])

        let storeURL = try sharedStoreURL()
        try repairLegacyTicketSizeIfNeeded(at: storeURL)
        let configuration = ModelConfiguration(
            "TicketParty",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func sharedStoreURL() throws -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["TICKETPARTY_STORE_PATH"], overridePath.isEmpty == false {
            let overrideURL = URL(fileURLWithPath: overridePath)
            let directoryURL = overrideURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return overrideURL
        }

        let appSupportURL = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        let directoryURL = appSupportURL.appendingPathComponent("TicketParty", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("TicketParty.store")
    }

    private static func repairLegacyTicketSizeIfNeeded(at storeURL: URL) throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return
        }

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil)
        guard openCode == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw sqliteError(database: database, code: openCode, operation: "open database")
        }
        defer { sqlite3_close(database) }

        guard tableExists(named: "ZTICKET", database: database) else {
            return
        }

        if columnExists(named: "ZSIZE", in: "ZTICKET", database: database) == false {
            try execute(
                sql: "ALTER TABLE ZTICKET ADD COLUMN ZSIZE VARCHAR",
                database: database,
                operation: "add ZSIZE column"
            )
        }

        if columnExists(named: "ZPRIORITY", in: "ZTICKET", database: database) {
            try execute(
                sql: """
                UPDATE ZTICKET
                SET ZSIZE = CASE
                    WHEN ZPRIORITY = 'low' THEN 'quick_tweak'
                    WHEN ZPRIORITY = 'medium' THEN 'straightforward_feature'
                    WHEN ZPRIORITY = 'high' THEN 'requires_thinking'
                    WHEN ZPRIORITY = 'urgent' THEN 'major_refactor'
                    ELSE ZSIZE
                END
                WHERE ZSIZE IS NULL OR ZSIZE = '';
                """,
                database: database,
                operation: "map legacy priority values to size"
            )
        }

        try execute(
            sql: """
            UPDATE ZTICKET
            SET ZSIZE = CASE
                WHEN ZSIZE IN ('quick_tweak', 'straightforward_feature', 'requires_thinking', 'major_refactor')
                    THEN ZSIZE
                ELSE 'straightforward_feature'
            END
            WHERE ZSIZE IS NULL
                OR ZSIZE = ''
                OR ZSIZE NOT IN ('quick_tweak', 'straightforward_feature', 'requires_thinking', 'major_refactor');
            """,
            database: database,
            operation: "backfill ticket size defaults"
        )
    }

    private static func tableExists(named tableName: String, database: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_text(statement, 1, tableName, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columnExists(named columnName: String, in tableName: String, database: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "PRAGMA table_info(\(tableName));"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let columnCString = sqlite3_column_text(statement, 1) else {
                continue
            }
            if String(cString: columnCString) == columnName {
                return true
            }
        }
        return false
    }

    private static func execute(
        sql: String,
        database: OpaquePointer?,
        operation: String
    ) throws {
        let execCode = sqlite3_exec(database, sql, nil, nil, nil)
        guard execCode == SQLITE_OK else {
            throw sqliteError(database: database, code: execCode, operation: operation)
        }
    }

    private static func sqliteError(
        database: OpaquePointer?,
        code: Int32,
        operation: String
    ) -> NSError {
        let message = database
            .flatMap { sqlite3_errmsg($0) }
            .map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(
            domain: "TicketPartyPersistence.SQLiteMigration",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Failed to \(operation): \(message)"]
        )
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
