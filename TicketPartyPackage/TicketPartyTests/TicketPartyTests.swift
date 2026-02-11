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
        usleep(10_000)
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
    func quickStatus_setsDoneTimestampAndClearsWhenReopened() {
        let ticket = Ticket(
            ticketNumber: 1,
            displayID: "TT-1",
            title: "Track done timestamp",
            description: "Ensure doneAt follows status changes",
            stateID: TicketQuickStatus.backlog.stateID
        )
        #expect(ticket.doneAt == nil)

        ticket.quickStatus = .done
        #expect(ticket.doneAt != nil)

        ticket.quickStatus = .inProgress
        #expect(ticket.doneAt == nil)
    }

    @Test
    func quickStatus_keepsExistingDoneTimestampAcrossTerminalStatuses() {
        let doneAt = Date(timeIntervalSince1970: 1_234_567)
        let ticket = Ticket(
            ticketNumber: 2,
            displayID: "TT-2",
            title: "Keep done timestamp",
            description: "Switch done -> skipped without resetting timestamp",
            stateID: TicketQuickStatus.done.stateID,
            doneAt: doneAt
        )

        ticket.quickStatus = .skipped
        #expect(ticket.doneAt == doneAt)
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

    @Test
    func loopManager_happyPath_completesRun() async throws {
        let projectID = UUID()
        let executor = LoopExecutorStub()
        let snapshotStore = LoopSnapshotStore(
            path: TestPaths.temporaryLoopSnapshotPath(),
            fileManager: .default
        )
        let manager = TicketLoopManager(
            executor: executor,
            snapshotStore: snapshotStore,
            cleanupSteps: [.verifyCleanWorktree]
        )

        try await manager.start(
            projectID: projectID,
            workingDirectory: "/tmp",
            tickets: [
                LoopTicketItem(
                    id: UUID(),
                    displayID: "TT-1",
                    title: "Ship feature",
                    description: "Implement the feature"
                ),
            ]
        )

        let terminal = try await waitForLoopTerminalState(manager: manager, projectID: projectID)
        guard case let .completed(summary) = terminal else {
            Issue.record("Expected completed loop state.")
            return
        }
        #expect(summary.cancelled == false)
        #expect(summary.completedTickets == 1)
    }

    @Test
    func loopManager_cleanupFailure_setsFailedState() async throws {
        let projectID = UUID()
        let executor = LoopExecutorStub(
            failuresByKind: [
                CleanupStep.verifyCleanWorktree.rawValue: "Worktree dirty.",
            ]
        )
        let snapshotStore = LoopSnapshotStore(
            path: TestPaths.temporaryLoopSnapshotPath(),
            fileManager: .default
        )
        let manager = TicketLoopManager(
            executor: executor,
            snapshotStore: snapshotStore,
            cleanupSteps: [.verifyCleanWorktree]
        )

        try await manager.start(
            projectID: projectID,
            workingDirectory: "/tmp",
            tickets: [
                LoopTicketItem(
                    id: UUID(),
                    displayID: "TT-2",
                    title: "Cleanup fails",
                    description: "Ensure failed state is captured"
                ),
            ]
        )

        let terminal = try await waitForLoopTerminalState(manager: manager, projectID: projectID)
        guard case let .failed(failure, _) = terminal else {
            Issue.record("Expected failed loop state.")
            return
        }
        #expect(failure.phase == CleanupStep.verifyCleanWorktree.rawValue)
    }

    @Test
    func loopManager_commitStep_sendsTicketTitleAndDescriptionInPayload() async throws {
        let projectID = UUID()
        let ticketID = UUID()
        let executor = LoopExecutorStub()
        let snapshotStore = LoopSnapshotStore(
            path: TestPaths.temporaryLoopSnapshotPath(),
            fileManager: .default
        )
        let manager = TicketLoopManager(
            executor: executor,
            snapshotStore: snapshotStore,
            cleanupSteps: [.commitImplementation]
        )

        try await manager.start(
            projectID: projectID,
            workingDirectory: "/tmp",
            tickets: [
                LoopTicketItem(
                    id: ticketID,
                    displayID: "TT-3",
                    title: "Commit context title",
                    description: "Commit context description"
                ),
            ]
        )

        _ = try await waitForLoopTerminalState(manager: manager, projectID: projectID)
        let commitCall = await executor.firstCall(kind: CleanupStep.commitImplementation.rawValue)
        let payload = try #require(commitCall?.payload)
        #expect(payload["ticketTitle"] == "Commit context title")
        #expect(payload["ticketDescription"] == "Commit context description")
    }

    @Test
    func navigationSelectionStore_roundTripsSidebarAndTicketSelection() throws {
        let suiteName = "TicketPartyTests.NavigationSelectionStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let projectID = UUID()
        let ticketID = UUID()
        let store = NavigationSelectionStore(userDefaults: defaults)

        store.saveSidebarSelection(.project(projectID))
        store.saveSelectedTicketID(ticketID, for: projectID)

        let reloadedStore = NavigationSelectionStore(userDefaults: defaults)
        #expect(reloadedStore.loadSidebarSelection() == .project(projectID))
        #expect(reloadedStore.loadSelectedTicketID(for: projectID) == ticketID)
    }

    @Test
    func navigationSelectionStore_clearsTicketSelectionForProject() throws {
        let suiteName = "TicketPartyTests.NavigationSelectionStore.Clear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let projectID = UUID()
        let store = NavigationSelectionStore(userDefaults: defaults)

        store.saveSelectedTicketID(UUID(), for: projectID)
        store.saveSelectedTicketID(nil, for: projectID)

        #expect(store.loadSelectedTicketID(for: projectID) == nil)
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

    private func waitForLoopTerminalState(
        manager: TicketLoopManager,
        projectID: UUID,
        timeoutSeconds: Double = 2.0
    ) async throws -> LoopRunState {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let state = await manager.state(projectID: projectID)
            switch state {
            case .completed, .failed, .paused:
                return state
            case .idle, .preparingQueue, .running, .cancelling:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw NSError(domain: "TicketPartyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Loop did not reach terminal state in time."])
    }
}

private struct TestPaths {
    static func temporaryLoopSnapshotPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TicketPartyLoopSnapshot-\(UUID().uuidString).json", isDirectory: false)
            .path
    }
}

private actor LoopExecutorStub: LoopTaskExecutor {
    struct Call: Sendable {
        let kind: String
        let payload: [String: String]
    }

    private let failuresByKind: [String: String]
    private var calls: [Call] = []

    init(failuresByKind: [String: String] = [:]) {
        self.failuresByKind = failuresByKind
    }

    func executeTask(
        projectID _: UUID,
        taskID: UUID,
        ticketID _: UUID,
        workingDirectory _: String,
        kind: String,
        idempotencyKey _: String,
        prompt _: String?,
        payload: [String: String]
    ) async throws -> LoopTaskExecutionResult {
        calls.append(Call(kind: kind, payload: payload))
        if let failure = failuresByKind[kind] {
            return LoopTaskExecutionResult(taskID: taskID, success: false, summary: failure)
        }
        return LoopTaskExecutionResult(taskID: taskID, success: true, summary: nil)
    }

    func cancelTask(projectID _: UUID, taskID _: UUID) async {}

    func firstCall(kind: String) -> Call? {
        calls.first(where: { $0.kind == kind })
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
