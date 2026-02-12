import Foundation
import SwiftData
import TicketPartyModels

public final class TicketTranscriptStore {
    public enum StoreError: LocalizedError {
        case runNotFound(UUID)
        case invalidUTF8Line
        case missingTranscriptFile(String)

        public var errorDescription: String? {
            switch self {
            case let .runNotFound(runID):
                "Transcript run not found: \(runID.uuidString)"
            case .invalidUTF8Line:
                "Failed to encode transcript line as UTF-8."
            case let .missingTranscriptFile(path):
                "Transcript file does not exist: \(path)"
            }
        }
    }

    private static let interruptedMessage = "Interrupted (app/supervisor restart)"

    private let fileManager: FileManager
    private let makeContainer: @Sendable () throws -> ModelContainer
    private let lock = NSLock()
    private var cachedContainer: ModelContainer?

    public init(
        fileManager: FileManager = .default,
        makeContainer: @escaping @Sendable () throws -> ModelContainer = { try TicketPartyPersistence.makeSharedContainer() }
    ) {
        self.fileManager = fileManager
        self.makeContainer = makeContainer
    }

    @discardableResult
    public func startRun(projectID: UUID, ticketID: UUID, requestID: UUID?) throws -> UUID {
        let runID = UUID()
        let now = Date()
        let relativePath = relativePath(projectID: projectID, ticketID: ticketID, runID: runID)

        let context = try makeContext()
        let run = TicketTranscriptRun(
            id: runID,
            projectID: projectID,
            ticketID: ticketID,
            requestID: requestID,
            status: .running,
            startedAt: now,
            completedAt: nil,
            summary: nil,
            errorMessage: nil,
            fileRelativePath: relativePath,
            lineCount: 0,
            byteCount: 0,
            createdAt: now,
            updatedAt: now
        )

        context.insert(run)
        try context.save()

        let fileURL = try absoluteURL(for: relativePath)
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path) == false {
            _ = fileManager.createFile(atPath: fileURL.path, contents: Data())
        }

        return runID
    }

    public func appendOutput(runID: UUID, line: String) throws {
        try appendLine(runID: runID, line: line)
    }

    public func appendError(runID: UUID, message: String) throws {
        try appendLine(runID: runID, line: "[ERROR] \(message)")
    }

    public func completeRun(runID: UUID, success: Bool, summary: String?) throws {
        let now = Date()
        let context = try makeContext()
        guard let run = try fetchRun(runID: runID, context: context) else {
            throw StoreError.runNotFound(runID)
        }

        run.status = success ? .succeeded : .failed
        run.completedAt = now
        run.updatedAt = now

        if success {
            run.summary = summary
            run.errorMessage = nil
        } else {
            run.summary = nil
            run.errorMessage = summary
        }

        try context.save()
    }

    public func markInterruptedRunsAsFailed(now: Date) throws {
        let runningRawValue = TicketTranscriptStatus.running.rawValue
        let context = try makeContext()
        let descriptor = FetchDescriptor<TicketTranscriptRun>(
            predicate: #Predicate<TicketTranscriptRun> { run in
                run.statusRaw == runningRawValue
            }
        )

        let runs = try context.fetch(descriptor)
        guard runs.isEmpty == false else { return }

        for run in runs {
            run.status = .failed
            run.completedAt = now
            run.summary = nil
            run.errorMessage = Self.interruptedMessage
            run.updatedAt = now
        }

        try context.save()
    }

    public func latestRun(ticketID: UUID) throws -> TicketTranscriptRun? {
        let context = try makeContext()
        let descriptor = FetchDescriptor<TicketTranscriptRun>(
            predicate: #Predicate<TicketTranscriptRun> { run in
                run.ticketID == ticketID
            },
            sortBy: [
                SortDescriptor(\TicketTranscriptRun.startedAt, order: .reverse),
                SortDescriptor(\TicketTranscriptRun.createdAt, order: .reverse),
            ]
        )
        return try context.fetch(descriptor).first
    }

    public func loadTranscript(runID: UUID, maxBytes: Int?) throws -> String {
        let context = try makeContext()
        guard let run = try fetchRun(runID: runID, context: context) else {
            throw StoreError.runNotFound(runID)
        }

        let fileURL = try absoluteURL(for: run.fileRelativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StoreError.missingTranscriptFile(run.fileRelativePath)
        }

        let data = try Data(contentsOf: fileURL)
        guard let maxBytes, maxBytes > 0, data.count > maxBytes else {
            return String(decoding: data, as: UTF8.self)
        }

        let suffix = Data(data.suffix(maxBytes))
        return String(decoding: suffix, as: UTF8.self)
    }

    private func appendLine(runID: UUID, line: String) throws {
        guard var encodedLine = line.data(using: .utf8) else {
            throw StoreError.invalidUTF8Line
        }
        encodedLine.append(0x0A)

        let context = try makeContext()
        guard let run = try fetchRun(runID: runID, context: context) else {
            throw StoreError.runNotFound(runID)
        }

        let fileURL = try absoluteURL(for: run.fileRelativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path) == false {
            _ = fileManager.createFile(atPath: fileURL.path, contents: Data())
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: encodedLine)

        run.lineCount += 1
        run.byteCount += Int64(encodedLine.count)
        run.updatedAt = .now

        try context.save()
    }

    private func fetchRun(runID: UUID, context: ModelContext) throws -> TicketTranscriptRun? {
        let descriptor = FetchDescriptor<TicketTranscriptRun>(
            predicate: #Predicate<TicketTranscriptRun> { run in
                run.id == runID
            }
        )
        return try context.fetch(descriptor).first
    }

    private func makeContext() throws -> ModelContext {
        try ModelContext(sharedContainer())
    }

    private func sharedContainer() throws -> ModelContainer {
        lock.lock()
        defer { lock.unlock() }

        if let cachedContainer {
            return cachedContainer
        }

        let container = try makeContainer()
        cachedContainer = container
        return container
    }

    private func relativePath(projectID: UUID, ticketID: UUID, runID: UUID) -> String {
        "transcripts/\(projectID.uuidString)/\(ticketID.uuidString)/\(runID.uuidString).log"
    }

    private func absoluteURL(for relativePath: String) throws -> URL {
        let baseURL = try applicationSupportRootURL()
        return baseURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    private func applicationSupportRootURL() throws -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["TICKETPARTY_STORE_PATH"], overridePath.isEmpty == false {
            let overrideURL = URL(fileURLWithPath: overridePath)
            let directoryURL = overrideURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return directoryURL
        }

        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL.appendingPathComponent("TicketParty", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
