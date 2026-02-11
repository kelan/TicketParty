import Darwin
import Foundation
import SwiftData
import Testing
import TicketPartyDataStore
import TicketPartyModels
@testable import TicketPartyUI

@Suite(.serialized)
struct TicketPartyTests {
    @Test
    func startRun_createsRowAndFile() throws {
        let env = try TestEnvironment()
        let store = TicketTranscriptStore()
        let projectID = UUID()
        let ticketID = UUID()

        let runID = try store.startRun(projectID: projectID, ticketID: ticketID, requestID: nil)

        let run = try #require(try store.latestRun(ticketID: ticketID))
        #expect(run.id == runID)
        #expect(run.status == .running)
        #expect(run.lineCount == 0)
        #expect(run.byteCount == 0)

        let transcriptURL = env.rootURL.appendingPathComponent(run.fileRelativePath)
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path))
    }

    @Test
    func appendOutput_updatesCountsAndFileContents() throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let runID = try store.startRun(projectID: UUID(), ticketID: UUID(), requestID: nil)

        try store.appendOutput(runID: runID, line: "first")
        try store.appendOutput(runID: runID, line: "second")

        let run = try #require(try fetchRun(runID: runID))
        #expect(run.lineCount == 2)
        #expect(run.byteCount == Int64("first\nsecond\n".utf8.count))

        let transcript = try store.loadTranscript(runID: runID, maxBytes: nil)
        #expect(transcript == "first\nsecond\n")
    }

    @Test
    func appendError_prefixesErrorLine() throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let runID = try store.startRun(projectID: UUID(), ticketID: UUID(), requestID: nil)

        try store.appendError(runID: runID, message: "something broke")

        let transcript = try store.loadTranscript(runID: runID, maxBytes: nil)
        #expect(transcript == "[ERROR] something broke\n")
    }

    @Test
    func completeRun_success_setsSucceededAndCompletedAt() throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let runID = try store.startRun(projectID: UUID(), ticketID: UUID(), requestID: nil)

        try store.completeRun(runID: runID, success: true, summary: "Done")

        let run = try #require(try fetchRun(runID: runID))
        #expect(run.status == .succeeded)
        #expect(run.summary == "Done")
        #expect(run.errorMessage == nil)
        #expect(run.completedAt != nil)
    }

    @Test
    func completeRun_failure_setsFailedAndError() throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let runID = try store.startRun(projectID: UUID(), ticketID: UUID(), requestID: nil)

        try store.completeRun(runID: runID, success: false, summary: "failed hard")

        let run = try #require(try fetchRun(runID: runID))
        #expect(run.status == .failed)
        #expect(run.summary == nil)
        #expect(run.errorMessage == "failed hard")
        #expect(run.completedAt != nil)
    }

    @Test
    func latestRun_returnsNewestForTicket() throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let ticketID = UUID()

        let first = try store.startRun(projectID: UUID(), ticketID: ticketID, requestID: nil)
        usleep(10000)
        let second = try store.startRun(projectID: UUID(), ticketID: ticketID, requestID: nil)

        let run = try #require(try store.latestRun(ticketID: ticketID))
        #expect(run.id == second)
        #expect(run.id != first)
    }

    @Test
    func loadTranscript_withMaxBytes_returnsTail() throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let runID = try store.startRun(projectID: UUID(), ticketID: UUID(), requestID: nil)

        try store.appendOutput(runID: runID, line: "abcde")
        try store.appendOutput(runID: runID, line: "fghij")

        let transcript = try store.loadTranscript(runID: runID, maxBytes: 6)
        #expect(transcript == "fghij\n")
    }

    @Test
    func markInterruptedRunsAsFailed_updatesRunningRows() throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let runID = try store.startRun(projectID: UUID(), ticketID: UUID(), requestID: nil)
        let now = Date(timeIntervalSince1970: 1_234_567)

        try store.markInterruptedRunsAsFailed(now: now)

        let run = try #require(try fetchRun(runID: runID))
        #expect(run.status == .failed)
        #expect(run.errorMessage == "Interrupted (app/supervisor restart)")
        #expect(run.completedAt == now)
    }

    @Test
    @MainActor
    func codexViewModel_streamEvents_persistTranscriptLifecycle() async throws {
        _ = try TestEnvironment()
        let store = TicketTranscriptStore()
        let viewModel = CodexViewModel(transcriptStore: store)

        let ticket = Ticket(
            ticketNumber: 1,
            displayID: "TT-1",
            title: "Sample ticket",
            description: "Do work"
        )
        let project = Project(
            name: "Sample project",
            workingDirectory: nil
        )

        await viewModel.send(ticket: ticket, project: project)

        let run = try #require(try store.latestRun(ticketID: ticket.id))
        #expect(run.status == .failed)
        #expect(run.errorMessage?.isEmpty == false)
    }

    private func fetchRun(runID: UUID) throws -> TicketTranscriptRun? {
        let container = try TicketPartyPersistence.makeSharedContainer()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TicketTranscriptRun>(
            predicate: #Predicate<TicketTranscriptRun> { run in
                run.id == runID
            }
        )
        return try context.fetch(descriptor).first
    }
}

private struct TestEnvironment: ~Copyable {
    let rootURL: URL
    private let previousStorePath: String?

    init() throws {
        previousStorePath = ProcessInfo.processInfo.environment["TICKETPARTY_STORE_PATH"]
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TicketPartyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let storePath = rootURL.appendingPathComponent("TicketParty.store", isDirectory: false).path
        setenv("TICKETPARTY_STORE_PATH", storePath, 1)
    }

    deinit {
        if let previousStorePath {
            setenv("TICKETPARTY_STORE_PATH", previousStorePath, 1)
        } else {
            unsetenv("TICKETPARTY_STORE_PATH")
        }
        try? FileManager.default.removeItem(at: rootURL)
    }
}
