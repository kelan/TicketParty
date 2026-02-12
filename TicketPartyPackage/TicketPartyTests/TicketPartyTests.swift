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
    func conversationStore_threadCreationAndModePersistence() throws {
        _ = try TestEnvironment()
        let store = TicketConversationStore()
        let ticketID = UUID()

        let thread = try store.ensureThread(ticketID: ticketID)
        #expect(thread.ticketID == ticketID)
        #expect(thread.mode == .plan)

        try store.setMode(ticketID: ticketID, mode: .implement)
        #expect(try store.mode(ticketID: ticketID) == .implement)
    }

    @Test
    func conversationStore_appendMessages_incrementsSequence() throws {
        _ = try TestEnvironment()
        let store = TicketConversationStore()
        let ticketID = UUID()

        let first = try store.appendUserMessage(ticketID: ticketID, text: "First")
        let second = try store.appendUserMessage(ticketID: ticketID, text: "Second")
        let assistant = try store.beginAssistantMessage(ticketID: ticketID, runID: nil)

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(assistant.sequence == 3)
    }

    @Test
    func conversationStore_replayBundle_returnsSummaryAndLatestWindow() throws {
        _ = try TestEnvironment()
        let store = TicketConversationStore()
        let ticketID = UUID()

        for index in 1 ... 5 {
            _ = try store.appendUserMessage(ticketID: ticketID, text: "Message \(index)")
        }

        let replay = try store.replayBundle(ticketID: ticketID, windowCount: 2, maxSummaryChars: 5_000)
        #expect(replay.messages.count == 2)
        #expect(replay.messages.map(\.content) == ["Message 4", "Message 5"])
        #expect(replay.summary.contains("user: Message 1"))
        #expect(replay.summary.contains("user: Message 3"))
    }

    @Test
    func conversationStore_compaction_respectsSummaryCap() throws {
        _ = try TestEnvironment()
        let store = TicketConversationStore()
        let ticketID = UUID()
        let longLine = String(repeating: "x", count: 240)

        for _ in 0 ..< 6 {
            _ = try store.appendUserMessage(ticketID: ticketID, text: longLine)
        }

        try store.compactIfNeeded(ticketID: ticketID, windowCount: 1, maxSummaryChars: 120)
        let replay = try store.replayBundle(ticketID: ticketID, windowCount: 1, maxSummaryChars: 120)

        #expect(replay.summary.count <= 120)
        #expect(replay.messages.count == 1)
        #expect(try store.messages(ticketID: ticketID).count == 1)
    }

    @Test
    func conversationStore_assistantStreaming_aggregatesLinesAndSetsRequiresResponse() throws {
        _ = try TestEnvironment()
        let store = TicketConversationStore()
        let ticketID = UUID()

        _ = try store.beginAssistantMessage(ticketID: ticketID, runID: nil)
        try store.appendAssistantOutput(ticketID: ticketID, line: "Do this first.")
        try store.appendAssistantOutput(ticketID: ticketID, line: "Can you confirm?")
        try store.completeAssistantMessage(ticketID: ticketID, success: true, errorSummary: nil)

        let messages = try store.messages(ticketID: ticketID)
        let assistant = try #require(messages.last)
        #expect(assistant.content == "Do this first.\nCan you confirm?")
        #expect(assistant.status == .completed)
        #expect(assistant.requiresResponse == true)
    }

    @Test
    func conversationStore_terminalFailure_updatesMessageAndTranscript() throws {
        _ = try TestEnvironment()
        let transcriptStore = TicketTranscriptStore()
        let conversationStore = TicketConversationStore()
        let ticketID = UUID()
        let runID = try transcriptStore.startRun(projectID: UUID(), ticketID: ticketID, requestID: nil)

        _ = try conversationStore.beginAssistantMessage(ticketID: ticketID, runID: runID)
        try conversationStore.appendAssistantOutput(ticketID: ticketID, line: "Working...")
        try conversationStore.completeAssistantMessage(ticketID: ticketID, success: false, errorSummary: "Failed.")
        try transcriptStore.completeRun(runID: runID, success: false, summary: "Failed.")

        let message = try #require(try conversationStore.messages(ticketID: ticketID).last)
        #expect(message.status == .failed)
        #expect(message.content.contains("Failed."))

        let run = try #require(try fetchRun(runID: runID))
        #expect(run.status == .failed)
        #expect(run.errorMessage == "Failed.")
    }

    @Test
    @MainActor
    func conversationViewModel_startImplementation_switchesModeAndAddsHandoffMessage() async throws {
        _ = try TestEnvironment()
        let container = try TicketPartyPersistence.makeSharedContainer()
        let context = ModelContext(container)
        let conversationStore = TicketConversationStore()
        let ticket = Ticket(
            ticketNumber: 42,
            displayID: "TT-42",
            title: "Ship thread mode transition",
            description: "Conversation handoff"
        )
        let project = Project(name: "Sample")
        context.insert(project)
        context.insert(ticket)
        try context.save()
        _ = try conversationStore.appendUserMessage(ticketID: ticket.id, text: "Let's plan this.")

        let viewModel = CodexViewModel(
            transcriptStore: TicketTranscriptStore(),
            conversationStore: conversationStore,
            startBackgroundTasks: false
        )
        viewModel.configure(modelContext: context)

        await viewModel.startImplementation(ticket: ticket, project: project)

        #expect(try conversationStore.mode(ticketID: ticket.id) == .implement)
        let persistedTicket = try #require(try fetchTicket(ticketID: ticket.id))
        #expect(persistedTicket.quickStatus == .inProgress)
        let messages = try conversationStore.messages(ticketID: ticket.id)
        #expect(messages.contains(where: { $0.role == .system && $0.content == "Mode switched to implement." }))
        #expect(messages.contains(where: { $0.role == .user && $0.content.contains("Start implementation now using the agreed plan.") }))
    }

    @Test
    func conversationStore_reloadsAcrossStoreInstances() throws {
        _ = try TestEnvironment()
        let ticketID = UUID()

        let firstStore = TicketConversationStore()
        _ = try firstStore.appendUserMessage(ticketID: ticketID, text: "Persist me")

        let secondStore = TicketConversationStore()
        let replay = try secondStore.replayBundle(ticketID: ticketID, windowCount: 12, maxSummaryChars: 12_000)
        #expect(replay.messages.contains(where: { $0.content == "Persist me" }))
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
    func quickStatus_newPlanningStatesAreActiveAndClearDoneTimestamp() {
        let doneAt = Date(timeIntervalSince1970: 1_234_567)
        let ticket = Ticket(
            ticketNumber: 3,
            displayID: "TT-3",
            title: "Planning state behavior",
            description: "Ensure planning states are non-terminal",
            stateID: TicketQuickStatus.done.stateID,
            doneAt: doneAt
        )

        ticket.quickStatus = .needsThinking
        #expect(ticket.quickStatus.isDone == false)
        #expect(ticket.doneAt == nil)

        ticket.quickStatus = .readyToImplement
        #expect(ticket.quickStatus.isDone == false)
        #expect(ticket.doneAt == nil)
    }

    @Test
    func codexManager_ticketTaskIdempotencyKey_includesTicketAndRun() {
        let ticketID = UUID()
        let runID = UUID()

        let key = CodexManager.ticketTaskIdempotencyKey(ticketID: ticketID, runID: runID)

        #expect(key == "ticket:\(ticketID.uuidString):run:\(runID.uuidString):step:codex")
    }

    @Test
    func codexManager_ticketTaskIdempotencyKey_changesAcrossRuns() {
        let ticketID = UUID()
        let firstRunID = UUID()
        let secondRunID = UUID()

        let firstKey = CodexManager.ticketTaskIdempotencyKey(ticketID: ticketID, runID: firstRunID)
        let secondKey = CodexManager.ticketTaskIdempotencyKey(ticketID: ticketID, runID: secondRunID)

        #expect(firstKey != secondKey)
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
    @MainActor
    func codexViewModel_startLoop_setsTicketInProgress_withConfiguredContext() async throws {
        _ = try TestEnvironment()
        let container = try TicketPartyPersistence.makeSharedContainer()
        let context = ModelContext(container)

        let project = Project(name: "Loop Project", workingDirectory: "/tmp")
        let ticket = Ticket(
            ticketNumber: 99,
            displayID: "TT-99",
            projectID: project.id,
            orderKey: TicketOrdering.keyStep,
            title: "Loop start status",
            description: "Set inProgress at task start",
            stateID: TicketQuickStatus.backlog.stateID
        )
        context.insert(project)
        context.insert(ticket)
        try context.save()

        let viewModel = CodexViewModel(
            manager: CodexManager(resumeSubscriptionsOnInit: false),
            startBackgroundTasks: true
        )
        viewModel.configure(modelContext: context)

        await viewModel.startLoop(project: project, tickets: [ticket])

        let persistedTicket = try #require(try fetchTicket(ticketID: ticket.id))
        #expect(persistedTicket.quickStatus == .inProgress)
    }

    @Test
    @MainActor
    func codexViewModel_startLoop_setsTicketInProgress_whenBackgroundTasksAreDisabled() async throws {
        _ = try TestEnvironment()
        let container = try TicketPartyPersistence.makeSharedContainer()
        let context = ModelContext(container)

        let project = Project(name: "Loop Project", workingDirectory: "/tmp")
        let ticket = Ticket(
            ticketNumber: 100,
            displayID: "TT-100",
            projectID: project.id,
            orderKey: TicketOrdering.keyStep,
            title: "Loop start status without event stream",
            description: "Set inProgress without consuming loop events",
            stateID: TicketQuickStatus.backlog.stateID
        )
        context.insert(project)
        context.insert(ticket)
        try context.save()

        let viewModel = CodexViewModel(
            manager: CodexManager(resumeSubscriptionsOnInit: false),
            startBackgroundTasks: false
        )
        viewModel.configure(modelContext: context)

        await viewModel.startLoop(project: project, tickets: [ticket])

        let persistedTicket = try #require(try fetchTicket(ticketID: ticket.id))
        #expect(persistedTicket.quickStatus == .inProgress)
    }

    @Test
    @MainActor
    func codexViewModel_missingContext_triggersDebugAssertionHandler_forLoopTaskStartStatusUpdate() async throws {
        var assertionMessages: [String] = []
        let viewModel = CodexViewModel(
            manager: CodexManager(resumeSubscriptionsOnInit: false),
            debugAssertionHandler: { message, _, _ in
                assertionMessages.append(message)
            },
            startBackgroundTasks: false
        )

        let project = Project(name: "Loop Project", workingDirectory: "/tmp")
        let ticket = Ticket(
            ticketNumber: 101,
            displayID: "TT-101",
            projectID: project.id,
            orderKey: TicketOrdering.keyStep,
            title: "Missing context assertion",
            description: "Trigger assertion hook",
            stateID: TicketQuickStatus.backlog.stateID
        )

        await viewModel.startLoop(project: project, tickets: [ticket])

        #expect(assertionMessages.count == 1)
        let message = try #require(assertionMessages.first)
        #expect(message.contains(TicketQuickStatus.inProgress.rawValue))
        #expect(message.contains(ticket.id.uuidString))
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

    @Test
    func supervisorHealthChecker_instanceTokenMismatch_fallsBackToHealthy() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("SupervisorHealthStub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recordPath = rootURL.appendingPathComponent("supervisor.json", isDirectory: false).path
        let socketPath = rootURL.appendingPathComponent("supervisor.sock", isDirectory: false).path

        let liveToken = "LIVE-TOKEN"
        let recordToken = "STALE-TOKEN"
        let expectedProtocol = 2
        let expectedPID = getpid()

        let server = try SupervisorHelloStub(
            socketPath: socketPath,
            instanceToken: liveToken,
            protocolVersion: expectedProtocol,
            pid: expectedPID,
            maxConnections: 2
        )
        try server.start()
        defer { server.stop() }

        let runtimeRecord: [String: Any] = [
            "pid": Int(expectedPID),
            "protocolVersion": expectedProtocol,
            "controlEndpoint": socketPath,
            "instanceToken": recordToken,
        ]
        let runtimeData = try JSONSerialization.data(withJSONObject: runtimeRecord)
        try runtimeData.write(to: URL(fileURLWithPath: recordPath), options: .atomic)

        let checker = CodexSupervisorHealthChecker(runtimeRecordPath: recordPath)
        let status = await checker.check()

        guard case let .healthy(pid, protocolVersion) = status else {
            Issue.record("Expected healthy status, got '\(status.title)' (\(status.detail)).")
            return
        }

        #expect(pid == expectedPID)
        #expect(protocolVersion == expectedProtocol)
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

    private func fetchTicket(ticketID: UUID) throws -> Ticket? {
        let container = try TicketPartyPersistence.makeSharedContainer()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Ticket>(
            predicate: #Predicate<Ticket> { ticket in
                ticket.id == ticketID
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

private final class SupervisorHelloStub: @unchecked Sendable {
    private let socketPath: String
    private let instanceToken: String
    private let protocolVersion: Int
    private let pid: Int32
    private let maxConnections: Int
    private var serverFD: Int32 = -1
    private var workItem: DispatchWorkItem?

    init(
        socketPath: String,
        instanceToken: String,
        protocolVersion: Int,
        pid: Int32,
        maxConnections: Int
    ) throws {
        self.socketPath = socketPath
        self.instanceToken = instanceToken
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.maxConnections = maxConnections
        _ = Darwin.unlink(socketPath)
    }

    deinit {
        stop()
    }

    func start() throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: "SupervisorHelloStub",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create socket: \(String(cString: strerror(errno)))."]
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let socketPathBytes = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPathBytes.count <= maxPathLength else {
            Darwin.close(fd)
            throw NSError(
                domain: "SupervisorHelloStub",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Socket path too long: \(socketPath)"]
            )
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            socketPathBytes.withUnsafeBytes { sourceBuffer in
                if let destination = rawBuffer.baseAddress, let source = sourceBuffer.baseAddress {
                    memcpy(destination, source, socketPathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw NSError(
                domain: "SupervisorHelloStub",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind socket: \(message)"]
            )
        }

        guard Darwin.listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw NSError(
                domain: "SupervisorHelloStub",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on socket: \(message)"]
            )
        }

        serverFD = fd
        let workItem = DispatchWorkItem { [fd, instanceToken, protocolVersion, pid, maxConnections] in
            var servedConnections = 0
            while servedConnections < maxConnections {
                var addressStorage = sockaddr()
                var addressLength = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = withUnsafeMutablePointer(to: &addressStorage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.accept(fd, sockaddrPointer, &addressLength)
                    }
                }

                if clientFD < 0 {
                    if errno == EINTR {
                        continue
                    }
                    break
                }

                Self.respondToHelloRequest(
                    clientFD: clientFD,
                    instanceToken: instanceToken,
                    protocolVersion: protocolVersion,
                    pid: pid
                )
                Darwin.close(clientFD)
                servedConnections += 1
            }
        }
        self.workItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    func stop() {
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        workItem?.cancel()
        workItem = nil
        _ = Darwin.unlink(socketPath)
    }

    private static func respondToHelloRequest(
        clientFD: Int32,
        instanceToken: String,
        protocolVersion: Int,
        pid: Int32
    ) {
        guard
            let line = readLine(from: clientFD),
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        let minimumProtocol = object["minProtocolVersion"] as? Int ?? 1
        if protocolVersion < minimumProtocol {
            sendLine(
                [
                    "type": "error",
                    "message": "Protocol version \(protocolVersion) is below required minimum \(minimumProtocol).",
                ],
                to: clientFD
            )
            return
        }

        if let expectedToken = object["expectedInstanceToken"] as? String, expectedToken != instanceToken {
            sendLine(
                [
                    "type": "error",
                    "message": "Instance token mismatch.",
                ],
                to: clientFD
            )
            return
        }

        sendLine(
            [
                "type": "hello.ok",
                "pid": Int(pid),
                "protocolVersion": protocolVersion,
                "instanceToken": instanceToken,
                "serverTimeEpochMS": Int64(Date().timeIntervalSince1970 * 1_000),
            ],
            to: clientFD
        )
    }

    private static func sendLine(_ object: [String: Any], to fd: Int32) {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var bytesWritten = 0
            while bytesWritten < payload.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: bytesWritten), payload.count - bytesWritten)
                if result > 0 {
                    bytesWritten += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func readLine(from fd: Int32, maxBytes: Int = 16_384) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)

        while data.count < maxBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.contains(0x0A) {
                    break
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }

        guard data.isEmpty == false else { return nil }

        let lineData: Data
        if let newlineIndex = data.firstIndex(of: 0x0A) {
            var candidate = data.prefix(upTo: newlineIndex)
            if candidate.last == 0x0D {
                candidate = candidate.dropLast()
            }
            lineData = Data(candidate)
        } else {
            lineData = data
        }

        return String(decoding: lineData, as: UTF8.self)
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
