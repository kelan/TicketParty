import Foundation

enum CleanupStep: String, Sendable, CaseIterable, Codable {
    case commitImplementation = "cleanup.commitImplementation"
    case requestRefactor = "cleanup.requestRefactor"
    case applyRefactor = "cleanup.applyRefactor"
    case commitRefactor = "cleanup.commitRefactor"
    case verifyCleanWorktree = "cleanup.verifyCleanWorktree"
    case runUnitTests = "cleanup.runUnitTests"

    static let `default`: [CleanupStep] = [
        .commitImplementation,
        .requestRefactor,
        .applyRefactor,
        .commitRefactor,
        .verifyCleanWorktree,
        .runUnitTests,
    ]
}

struct LoopTicketItem: Sendable, Codable, Equatable {
    let id: UUID
    let displayID: String
    let title: String
    let description: String
}

enum PauseReason: String, Sendable, Codable, Equatable {
    case userRequested
}

struct FailureContext: Sendable, Codable, Equatable {
    let ticketID: UUID?
    let phase: String
    let message: String
}

struct RunSummary: Sendable, Codable, Equatable {
    let runID: UUID
    let projectID: UUID
    let totalTickets: Int
    let completedTickets: Int
    let cancelled: Bool
    let finishedAt: Date
}

enum TicketPhase: Sendable, Codable, Equatable {
    case sendingToCodex
    case awaitingCodexResult
    case runningCleanup(step: CleanupStep, stepIndex: Int, totalSteps: Int)
    case markingDone
}

struct RunProgress: Sendable, Codable, Equatable {
    let projectID: UUID
    let runID: UUID
    let total: Int
    let index: Int
    let currentTicketID: UUID?
    let ticketPhase: TicketPhase?
}

enum LoopRunState: Sendable, Codable, Equatable {
    case idle
    case preparingQueue
    case running(RunProgress)
    case paused(PauseReason, RunProgress)
    case failed(FailureContext, RunProgress)
    case completed(RunSummary)
    case cancelling(RunProgress)
}

struct LoopRunSnapshot: Codable, Sendable, Equatable {
    let runID: UUID
    let projectID: UUID
    let workingDirectory: String
    let queuedTickets: [LoopTicketItem]
    let completedTicketIDs: [UUID]
    let nextIndex: Int
    let failedTicketID: UUID?
    let state: LoopRunState
    let updatedAt: Date
}

struct LoopTaskExecutionResult: Sendable, Equatable {
    let taskID: UUID
    let success: Bool
    let summary: String?
}

protocol LoopTaskExecutor: Sendable {
    func executeTask(
        projectID: UUID,
        taskID: UUID,
        ticketID: UUID,
        workingDirectory: String,
        kind: String,
        idempotencyKey: String,
        prompt: String?,
        payload: [String: String]
    ) async throws -> LoopTaskExecutionResult
    func cancelTask(projectID: UUID, taskID: UUID) async
}

actor LoopSnapshotStore {
    private let url: URL
    private let fileManager: FileManager

    init(
        path: String = "$HOME/Library/Application Support/TicketParty/runtime/loop-snapshots.json",
        fileManager: FileManager = .default
    ) {
        url = URL(fileURLWithPath: Self.expandPath(path))
        self.fileManager = fileManager
    }

    func load(projectID: UUID) throws -> LoopRunSnapshot? {
        try loadAll()[projectID]
    }

    func save(_ snapshot: LoopRunSnapshot) throws {
        var snapshots = try loadAll()
        snapshots[snapshot.projectID] = snapshot
        try persist(snapshots)
    }

    func clear(projectID: UUID) throws {
        var snapshots = try loadAll()
        snapshots.removeValue(forKey: projectID)
        try persist(snapshots)
    }

    private func loadAll() throws -> [UUID: LoopRunSnapshot] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([String: LoopRunSnapshot].self, from: data)
        var result: [UUID: LoopRunSnapshot] = [:]
        for (projectIDRaw, snapshot) in decoded {
            guard let projectID = UUID(uuidString: projectIDRaw) else { continue }
            result[projectID] = snapshot
        }
        return result
    }

    private func persist(_ snapshots: [UUID: LoopRunSnapshot]) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyed = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(keyed)
        try data.write(to: url, options: .atomic)
    }

    private nonisolated static func expandPath(_ path: String) -> String {
        let expandedTilde = (path as NSString).expandingTildeInPath
        let homeDirectory = NSHomeDirectory()
        let expandedEnv = expandedTilde
            .replacingOccurrences(of: "${HOME}", with: homeDirectory)
            .replacingOccurrences(of: "$HOME", with: homeDirectory)
        return URL(fileURLWithPath: expandedEnv).standardizedFileURL.path
    }
}

actor TicketLoopManager {
    enum Event: Sendable {
        case stateChanged(projectID: UUID, state: LoopRunState)
        case ticketStarted(projectID: UUID, ticketID: UUID, index: Int, total: Int)
        case ticketFinished(projectID: UUID, ticketID: UUID, success: Bool, message: String?)
        case cleanupStepStarted(projectID: UUID, ticketID: UUID, step: CleanupStep)
        case cleanupStepFinished(projectID: UUID, ticketID: UUID, step: CleanupStep, success: Bool, message: String?)
    }

    private struct ActiveRun: Sendable {
        let runID: UUID
        let projectID: UUID
        let workingDirectory: String
        let queue: [LoopTicketItem]
        var completedTicketIDs: [UUID]
        var nextIndex: Int
        var failedTicketID: UUID?
        var state: LoopRunState
        var activeTaskID: UUID?
        var pauseRequested: Bool
        var cancelRequested: Bool
    }

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let executor: LoopTaskExecutor
    private let snapshotStore: LoopSnapshotStore
    private let cleanupSteps: [CleanupStep]

    private var runs: [UUID: ActiveRun] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]

    init(
        executor: LoopTaskExecutor,
        snapshotStore: LoopSnapshotStore = LoopSnapshotStore(),
        cleanupSteps: [CleanupStep] = CleanupStep.default
    ) {
        var streamContinuation: AsyncStream<Event>.Continuation?
        events = AsyncStream<Event> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation!

        self.executor = executor
        self.snapshotStore = snapshotStore
        self.cleanupSteps = cleanupSteps
    }

    deinit {
        for task in runTasks.values {
            task.cancel()
        }
        continuation.finish()
    }

    func state(projectID: UUID) -> LoopRunState {
        runs[projectID]?.state ?? .idle
    }

    func start(projectID: UUID, workingDirectory: String, tickets: [LoopTicketItem]) async throws {
        guard runTasks[projectID] == nil else {
            throw TicketLoopError.alreadyRunning
        }
        let queue = tickets.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard queue.isEmpty == false else {
            throw TicketLoopError.noTickets
        }

        let runID = UUID()
        let initial = ActiveRun(
            runID: runID,
            projectID: projectID,
            workingDirectory: workingDirectory,
            queue: queue,
            completedTicketIDs: [],
            nextIndex: 0,
            failedTicketID: nil,
            state: .preparingQueue,
            activeTaskID: nil,
            pauseRequested: false,
            cancelRequested: false
        )
        runs[projectID] = initial
        continuation.yield(.stateChanged(projectID: projectID, state: .preparingQueue))
        try await persistSnapshot(for: projectID)
        startRunTask(projectID: projectID)
    }

    func pause(projectID: UUID) async {
        guard var run = runs[projectID] else { return }
        run.pauseRequested = true
        runs[projectID] = run
    }

    func resume(projectID: UUID, workingDirectory: String, fallbackTickets: [LoopTicketItem]) async throws {
        guard runTasks[projectID] == nil else {
            throw TicketLoopError.alreadyRunning
        }

        if var run = runs[projectID] {
            run.pauseRequested = false
            run.cancelRequested = false
            runs[projectID] = run
            startRunTask(projectID: projectID)
            return
        }

        if let snapshot = try await snapshotStore.load(projectID: projectID) {
            let restored = ActiveRun(
                runID: snapshot.runID,
                projectID: snapshot.projectID,
                workingDirectory: snapshot.workingDirectory,
                queue: snapshot.queuedTickets,
                completedTicketIDs: snapshot.completedTicketIDs,
                nextIndex: snapshot.nextIndex,
                failedTicketID: snapshot.failedTicketID,
                state: snapshot.state,
                activeTaskID: nil,
                pauseRequested: false,
                cancelRequested: false
            )
            runs[projectID] = restored
            startRunTask(projectID: projectID)
            return
        }

        try await start(projectID: projectID, workingDirectory: workingDirectory, tickets: fallbackTickets)
    }

    func cancel(projectID: UUID) async {
        guard var run = runs[projectID] else { return }
        run.cancelRequested = true
        run.pauseRequested = false

        let progress = progress(for: run, phase: runPhase(from: run.state))
        run.state = .cancelling(progress)
        runs[projectID] = run
        continuation.yield(.stateChanged(projectID: projectID, state: run.state))

        if let activeTaskID = run.activeTaskID {
            await executor.cancelTask(projectID: projectID, taskID: activeTaskID)
        }
    }

    private func startRunTask(projectID: UUID) {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.runLoop(projectID: projectID)
        }
        runTasks[projectID] = task
    }

    private func runLoop(projectID: UUID) async {
        defer {
            runTasks.removeValue(forKey: projectID)
        }

        while true {
            guard var run = runs[projectID] else { return }

            if run.cancelRequested {
                await finishCancelled(projectID: projectID, run: run)
                return
            }

            if run.pauseRequested {
                let progress = progress(for: run, phase: runPhase(from: run.state))
                run.state = .paused(.userRequested, progress)
                runs[projectID] = run
                continuation.yield(.stateChanged(projectID: projectID, state: run.state))
                try? await persistSnapshot(for: projectID)
                return
            }

            if run.nextIndex >= run.queue.count {
                await finishCompleted(projectID: projectID, run: run)
                return
            }

            let ticket = run.queue[run.nextIndex]
            continuation.yield(
                .ticketStarted(
                    projectID: projectID,
                    ticketID: ticket.id,
                    index: run.nextIndex + 1,
                    total: run.queue.count
                )
            )

            let sendingPhase = TicketPhase.sendingToCodex
            run.state = .running(progress(for: run, phase: sendingPhase, currentTicketID: ticket.id))
            runs[projectID] = run
            continuation.yield(.stateChanged(projectID: projectID, state: run.state))
            try? await persistSnapshot(for: projectID)

            do {
                let codexResult = try await executeCodexStep(run: run, ticket: ticket)
                run = runs[projectID] ?? run
                run.activeTaskID = nil
                runs[projectID] = run

                if codexResult.success == false {
                    if run.cancelRequested {
                        await finishCancelled(projectID: projectID, run: run)
                        return
                    }
                    await fail(
                        projectID: projectID,
                        run: run,
                        ticketID: ticket.id,
                        phase: "codex.ticket",
                        message: codexResult.summary ?? "Codex task failed."
                    )
                    continuation.yield(
                        .ticketFinished(
                            projectID: projectID,
                            ticketID: ticket.id,
                            success: false,
                            message: codexResult.summary
                        )
                    )
                    return
                }
            } catch {
                run = runs[projectID] ?? run
                run.activeTaskID = nil
                runs[projectID] = run
                if run.cancelRequested {
                    await finishCancelled(projectID: projectID, run: run)
                    return
                }
                await fail(
                    projectID: projectID,
                    run: run,
                    ticketID: ticket.id,
                    phase: "codex.ticket",
                    message: error.localizedDescription
                )
                continuation.yield(
                    .ticketFinished(
                        projectID: projectID,
                        ticketID: ticket.id,
                        success: false,
                        message: error.localizedDescription
                    )
                )
                return
            }

            for (stepIndex, step) in cleanupSteps.enumerated() {
                guard var currentRun = runs[projectID] else { return }

                if currentRun.cancelRequested {
                    await finishCancelled(projectID: projectID, run: currentRun)
                    return
                }

                if currentRun.pauseRequested {
                    let pauseProgress = progress(
                        for: currentRun,
                        phase: .runningCleanup(step: step, stepIndex: stepIndex + 1, totalSteps: cleanupSteps.count),
                        currentTicketID: ticket.id
                    )
                    currentRun.state = .paused(.userRequested, pauseProgress)
                    runs[projectID] = currentRun
                    continuation.yield(.stateChanged(projectID: projectID, state: currentRun.state))
                    try? await persistSnapshot(for: projectID)
                    return
                }

                let cleanupPhase = TicketPhase.runningCleanup(
                    step: step,
                    stepIndex: stepIndex + 1,
                    totalSteps: cleanupSteps.count
                )
                currentRun.state = .running(progress(for: currentRun, phase: cleanupPhase, currentTicketID: ticket.id))
                runs[projectID] = currentRun
                continuation.yield(.stateChanged(projectID: projectID, state: currentRun.state))
                continuation.yield(.cleanupStepStarted(projectID: projectID, ticketID: ticket.id, step: step))
                try? await persistSnapshot(for: projectID)

                do {
                    let cleanupResult = try await executeCleanupStep(
                        run: currentRun,
                        ticket: ticket,
                        step: step
                    )
                    currentRun = runs[projectID] ?? currentRun
                    currentRun.activeTaskID = nil
                    runs[projectID] = currentRun

                    continuation.yield(
                        .cleanupStepFinished(
                            projectID: projectID,
                            ticketID: ticket.id,
                            step: step,
                            success: cleanupResult.success,
                            message: cleanupResult.summary
                        )
                    )

                    if cleanupResult.success == false {
                        if currentRun.cancelRequested {
                            await finishCancelled(projectID: projectID, run: currentRun)
                            return
                        }
                        await fail(
                            projectID: projectID,
                            run: currentRun,
                            ticketID: ticket.id,
                            phase: step.rawValue,
                            message: cleanupResult.summary ?? "Cleanup step failed."
                        )
                        continuation.yield(
                            .ticketFinished(
                                projectID: projectID,
                                ticketID: ticket.id,
                                success: false,
                                message: cleanupResult.summary
                            )
                        )
                        return
                    }
                } catch {
                    currentRun = runs[projectID] ?? currentRun
                    currentRun.activeTaskID = nil
                    runs[projectID] = currentRun
                    if currentRun.cancelRequested {
                        await finishCancelled(projectID: projectID, run: currentRun)
                        return
                    }
                    continuation.yield(
                        .cleanupStepFinished(
                            projectID: projectID,
                            ticketID: ticket.id,
                            step: step,
                            success: false,
                            message: error.localizedDescription
                        )
                    )
                    await fail(
                        projectID: projectID,
                        run: currentRun,
                        ticketID: ticket.id,
                        phase: step.rawValue,
                        message: error.localizedDescription
                    )
                    continuation.yield(
                        .ticketFinished(
                            projectID: projectID,
                            ticketID: ticket.id,
                            success: false,
                            message: error.localizedDescription
                        )
                    )
                    return
                }
            }

            guard var completedRun = runs[projectID] else { return }
            completedRun.completedTicketIDs.append(ticket.id)
            completedRun.nextIndex += 1
            completedRun.state = .running(
                progress(
                    for: completedRun,
                    phase: .markingDone,
                    currentTicketID: ticket.id
                )
            )
            runs[projectID] = completedRun
            continuation.yield(
                .ticketFinished(
                    projectID: projectID,
                    ticketID: ticket.id,
                    success: true,
                    message: nil
                )
            )
            continuation.yield(.stateChanged(projectID: projectID, state: completedRun.state))
            try? await persistSnapshot(for: projectID)
        }
    }

    private func executeCodexStep(run: ActiveRun, ticket: LoopTicketItem) async throws -> LoopTaskExecutionResult {
        let idempotencyKey = "run:\(run.runID.uuidString):ticket:\(ticket.id.uuidString):step:codex"
        let prompt = "\(ticket.title)\n\(ticket.description)"
        let taskID = UUID()
        if var refreshed = runs[run.projectID] {
            refreshed.activeTaskID = taskID
            runs[run.projectID] = refreshed
        }
        return try await executor.executeTask(
            projectID: run.projectID,
            taskID: taskID,
            ticketID: ticket.id,
            workingDirectory: run.workingDirectory,
            kind: "codex.ticket",
            idempotencyKey: idempotencyKey,
            prompt: prompt,
            payload: [:]
        )
    }

    private func executeCleanupStep(
        run: ActiveRun,
        ticket: LoopTicketItem,
        step: CleanupStep
    ) async throws -> LoopTaskExecutionResult {
        let idempotencyKey = "run:\(run.runID.uuidString):ticket:\(ticket.id.uuidString):step:\(step.rawValue)"
        var payload: [String: String] = [
            "runID": run.runID.uuidString,
            "ticketID": ticket.id.uuidString,
            "ticketTitle": ticket.title,
            "ticketDescription": ticket.description,
            "workingDirectory": run.workingDirectory,
        ]

        var prompt: String?
        switch step {
        case .commitImplementation:
            payload["commitType"] = "implementation"
            payload["baseMessage"] = "Implement \(ticket.displayID): \(ticket.title)"
            payload["includeAgentTrailer"] = "true"
        case .requestRefactor:
            prompt =
                """
                Review the changes for ticket \(ticket.displayID) and propose high-value refactors.
                Ticket title: \(ticket.title)
                Ticket description: \(ticket.description)
                """
        case .applyRefactor:
            prompt =
                """
                Apply the best refactor opportunities for ticket \(ticket.displayID) while preserving behavior.
                Ticket title: \(ticket.title)
                Ticket description: \(ticket.description)
                """
        case .commitRefactor:
            payload["commitType"] = "refactor"
            payload["baseMessage"] = "Refactor \(ticket.displayID): \(ticket.title)"
            payload["includeAgentTrailer"] = "true"
        case .verifyCleanWorktree:
            break
        case .runUnitTests:
            payload["command"] =
                """
                xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' test -only-testing:TicketPartyTests
                """
        }

        let taskID = UUID()
        if var refreshed = runs[run.projectID] {
            refreshed.activeTaskID = taskID
            runs[run.projectID] = refreshed
        }
        return try await executor.executeTask(
            projectID: run.projectID,
            taskID: taskID,
            ticketID: ticket.id,
            workingDirectory: run.workingDirectory,
            kind: step.rawValue,
            idempotencyKey: idempotencyKey,
            prompt: prompt,
            payload: payload
        )
    }

    private func fail(
        projectID: UUID,
        run: ActiveRun,
        ticketID: UUID?,
        phase: String,
        message: String
    ) async {
        var failedRun = run
        failedRun.failedTicketID = ticketID
        let failure = FailureContext(ticketID: ticketID, phase: phase, message: message)
        let progress = progress(for: failedRun, phase: runPhase(from: failedRun.state), currentTicketID: ticketID)
        failedRun.state = .failed(failure, progress)
        failedRun.activeTaskID = nil
        runs[projectID] = failedRun
        continuation.yield(.stateChanged(projectID: projectID, state: failedRun.state))
        try? await persistSnapshot(for: projectID)
    }

    private func finishCompleted(projectID: UUID, run: ActiveRun) async {
        let summary = RunSummary(
            runID: run.runID,
            projectID: run.projectID,
            totalTickets: run.queue.count,
            completedTickets: run.completedTicketIDs.count,
            cancelled: false,
            finishedAt: .now
        )
        var completedRun = run
        completedRun.state = .completed(summary)
        completedRun.activeTaskID = nil
        runs[projectID] = completedRun
        continuation.yield(.stateChanged(projectID: projectID, state: completedRun.state))
        try? await snapshotStore.clear(projectID: projectID)
    }

    private func finishCancelled(projectID: UUID, run: ActiveRun) async {
        let summary = RunSummary(
            runID: run.runID,
            projectID: run.projectID,
            totalTickets: run.queue.count,
            completedTickets: run.completedTicketIDs.count,
            cancelled: true,
            finishedAt: .now
        )
        var cancelledRun = run
        cancelledRun.state = .completed(summary)
        cancelledRun.activeTaskID = nil
        runs[projectID] = cancelledRun
        continuation.yield(.stateChanged(projectID: projectID, state: cancelledRun.state))
        try? await snapshotStore.clear(projectID: projectID)
    }

    private func persistSnapshot(for projectID: UUID) async throws {
        guard let run = runs[projectID] else { return }
        let snapshot = LoopRunSnapshot(
            runID: run.runID,
            projectID: run.projectID,
            workingDirectory: run.workingDirectory,
            queuedTickets: run.queue,
            completedTicketIDs: run.completedTicketIDs,
            nextIndex: run.nextIndex,
            failedTicketID: run.failedTicketID,
            state: run.state,
            updatedAt: .now
        )
        try await snapshotStore.save(snapshot)
    }

    private func runPhase(from state: LoopRunState) -> TicketPhase? {
        switch state {
        case let .running(progress), let .paused(_, progress), let .failed(_, progress), let .cancelling(progress):
            return progress.ticketPhase
        case .idle, .preparingQueue, .completed:
            return nil
        }
    }

    private func progress(
        for run: ActiveRun,
        phase: TicketPhase?,
        currentTicketID: UUID? = nil
    ) -> RunProgress {
        RunProgress(
            projectID: run.projectID,
            runID: run.runID,
            total: run.queue.count,
            index: min(run.nextIndex + 1, max(run.queue.count, 1)),
            currentTicketID: currentTicketID ?? run.queue[safe: run.nextIndex]?.id,
            ticketPhase: phase
        )
    }
}

enum TicketLoopError: LocalizedError {
    case alreadyRunning
    case noTickets

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A loop is already running for this project."
        case .noTickets:
            return "No eligible tickets are available for this loop."
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
