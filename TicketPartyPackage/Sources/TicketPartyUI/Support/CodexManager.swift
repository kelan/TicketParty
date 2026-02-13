import Darwin
import Foundation
import Observation
import OSLog
import SwiftData
import TicketPartyDataStore
import TicketPartyModels

enum CodexProjectStatus: Sendable, Equatable {
    case stopped
    case starting
    case running
    case error(String)

    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case let .error(message):
            "Error: \(message)"
        }
    }
}

actor CodexManager {
    private static let controlProtocolMaxLineBytes = 1_048_576

    enum TaskMode: String, Sendable {
        case plan
        case implement

        init(conversationMode: TicketConversationMode) {
            switch conversationMode {
            case .plan:
                self = .plan
            case .implement:
                self = .implement
            }
        }
    }

    enum Event: Sendable {
        case statusChanged(projectID: UUID, status: CodexProjectStatus)
        case ticketStarted(ticketID: UUID)
        case ticketOutput(ticketID: UUID, line: String)
        case ticketError(ticketID: UUID, message: String)
        case ticketCompleted(ticketID: UUID, success: Bool, summary: String?)
    }

    enum ManagerError: LocalizedError {
        case missingWorkingDirectory
        case invalidWorkingDirectory(String)
        case supervisorUnavailable(String)
        case invalidResponse(String)
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingWorkingDirectory:
                "Project working directory is required before sending to Codex."
            case let .invalidWorkingDirectory(path):
                "Project working directory is invalid: \(path)"
            case let .supervisorUnavailable(message):
                "Could not reach codex-supervisor: \(message)"
            case let .invalidResponse(message):
                "Supervisor returned invalid data: \(message)"
            case let .requestFailed(message):
                "Supervisor request failed: \(message)"
            }
        }
    }

    private struct SubmitTaskRequest: Encodable {
        let type = "submitTask"
        let projectID: String
        let taskID: String
        let kind: String
        let mode: String
        let ticketID: String?
        let idempotencyKey: String?
        let workingDirectory: String?
        let prompt: String?
        let payload: [String: String]?
    }

    private struct SubscribeRequest: Encodable {
        let type = "subscribe"
        let projectID: String?
        let fromEventID: Int64?
    }

    private struct WorkerStatusRequest: Encodable {
        let type = "workerStatus"
        let projectID: String?
    }

    private struct StopWorkerRequest: Encodable {
        let type = "stopWorker"
        let projectID: String
    }

    private struct CancelTaskRequest: Encodable {
        let type = "cancelTask"
        let projectID: String
        let taskID: String
    }

    private struct AckRequest: Encodable {
        let type = "ack"
        let projectID: String
        let upToEventID: Int64
    }

    private struct ListActiveTasksRequest: Encodable {
        let type = "listActiveTasks"
    }

    private struct TaskStatusRequest: Encodable {
        let type = "taskStatus"
        let taskID: String?
        let projectID: String?
    }

    private struct TaskStatusSnapshot: Sendable {
        let taskID: UUID
        let state: String
        let success: Bool?
        let summary: String?

        var isTerminal: Bool {
            state == "completed" || state == "failed"
        }
    }

    private struct SubmitTaskResult: Sendable {
        let taskID: UUID
        let deduplicated: Bool
    }

    private struct TaskTerminalResult: Sendable, Equatable {
        let taskID: UUID
        let success: Bool
        let summary: String?
    }

    private struct ActiveTaskSnapshot: Sendable {
        let projectID: UUID
    }

    private struct WorkerSnapshot: Sendable {
        struct ActiveRequest: Sendable {
            let requestID: UUID
            let ticketID: UUID?
            let mode: TaskMode
        }

        let projectID: UUID
        let isRunning: Bool
        let activeRequests: [ActiveRequest]
    }

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let fileManager: FileManager
    private let supervisorSocketPath: String
    private let cursorStorePath: String

    private var statuses: [UUID: CodexProjectStatus] = [:]
    private var requestToTicket: [UUID: UUID] = [:]
    private var requestToProject: [UUID: UUID] = [:]
    private var requestsUsingTaskEvents: Set<UUID> = []
    private var userStoppedProjects: Set<UUID> = []
    private var subscriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var cursorByProject: [UUID: Int64] = [:]
    private var taskTerminalResults: [UUID: TaskTerminalResult] = [:]
    private var taskWaiters: [UUID: [CheckedContinuation<TaskTerminalResult, Never>]] = [:]

    init(
        supervisorSocketPath: String = "$HOME/Library/Application Support/TicketParty/runtime/supervisor.sock",
        cursorStorePath: String = "$HOME/Library/Application Support/TicketParty/runtime/supervisor-cursors.json",
        fileManager: FileManager = .default,
        resumeSubscriptionsOnInit: Bool = true
    ) {
        var streamContinuation: AsyncStream<Event>.Continuation?
        events = AsyncStream<Event> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation!

        self.fileManager = fileManager
        self.supervisorSocketPath = Self.expandPath(supervisorSocketPath)
        self.cursorStorePath = Self.expandPath(cursorStorePath)
        cursorByProject = Self.loadCursorStore(path: Self.expandPath(cursorStorePath))

        if resumeSubscriptionsOnInit {
            Task { [weak self] in
                await self?.resumeProjectSubscriptionsForActiveTasks()
            }
        }
    }

    static func ticketTaskIdempotencyKey(ticketID: UUID, runID: UUID) -> String {
        "ticket:\(ticketID.uuidString):run:\(runID.uuidString):step:codex"
    }

    deinit {
        for task in subscriptionTasks.values {
            task.cancel()
        }
        continuation.finish()
    }

    func status(for projectID: UUID) -> CodexProjectStatus {
        statuses[projectID] ?? .stopped
    }

    func executeTask(
        projectID: UUID,
        taskID: UUID,
        ticketID: UUID,
        workingDirectory: String,
        kind: String,
        idempotencyKey: String,
        prompt: String?,
        payload: [String: String]
    ) async throws -> LoopTaskExecutionResult {
        let resolvedWorkingDirectory = try resolveWorkingDirectory(workingDirectory)
        ensureProjectSubscription(projectID: projectID)

        let submit = try await submitTask(
            projectID: projectID,
            taskID: taskID,
            ticketID: ticketID,
            kind: kind,
            mode: .implement,
            idempotencyKey: idempotencyKey,
            workingDirectory: resolvedWorkingDirectory,
            prompt: prompt,
            payload: payload
        )

        requestToTicket[submit.taskID] = ticketID
        requestToProject[submit.taskID] = projectID
        setStatus(.running, for: projectID)

        if submit.deduplicated, let current = try fetchTaskStatus(taskID: submit.taskID), current.isTerminal {
            let result = TaskTerminalResult(
                taskID: current.taskID,
                success: current.success ?? false,
                summary: current.summary
            )
            completeTask(result)
            return LoopTaskExecutionResult(taskID: result.taskID, success: result.success, summary: result.summary)
        }

        let terminal = await waitForTaskCompletion(taskID: submit.taskID)
        return LoopTaskExecutionResult(taskID: terminal.taskID, success: terminal.success, summary: terminal.summary)
    }

    func cancelTask(projectID: UUID, taskID: UUID) async {
        let request = CancelTaskRequest(projectID: projectID.uuidString, taskID: taskID.uuidString)
        guard let payload = try? Self.encodeLine(request) else { return }
        _ = try? Self.sendRequest(
            payload: payload,
            socketPath: supervisorSocketPath,
            receiveTimeout: 5,
            sendTimeout: 5
        )
    }

    func cancelTicketTasks(projectID: UUID, ticketID: UUID) async {
        var activeTaskIDs: [UUID] = []
        for (taskID, mappedTicketID) in requestToTicket {
            guard mappedTicketID == ticketID, requestToProject[taskID] == projectID else { continue }
            activeTaskIDs.append(taskID)
        }

        for taskID in activeTaskIDs {
            await cancelTask(projectID: projectID, taskID: taskID)
        }
    }

    func sendTicket(
        projectID: UUID,
        workingDirectory: String?,
        ticketID: UUID,
        idempotencyKey: String,
        mode: TicketConversationMode,
        prompt: String
    ) async throws {
        let resolvedWorkingDirectory = try resolveWorkingDirectory(workingDirectory)
        ensureProjectSubscription(projectID: projectID)

        let submit = try await submitTask(
            projectID: projectID,
            ticketID: ticketID,
            kind: "codex.ticket",
            mode: TaskMode(conversationMode: mode),
            idempotencyKey: idempotencyKey,
            workingDirectory: resolvedWorkingDirectory,
            prompt: prompt,
            payload: [:]
        )

        if submit.deduplicated, let current = try fetchTaskStatus(taskID: submit.taskID), current.isTerminal {
            continuation.yield(
                .ticketCompleted(
                    ticketID: ticketID,
                    success: current.success ?? false,
                    summary: current.summary
                )
            )
            return
        }

        requestToTicket[submit.taskID] = ticketID
        requestToProject[submit.taskID] = projectID
        // submitTask.ok confirms supervisor accepted the request; treat project as active.
        setStatus(.running, for: projectID)
    }

    func sendTicket(
        projectID: UUID,
        workingDirectory: String?,
        ticketID: UUID,
        idempotencyKey: String,
        mode: TicketConversationMode,
        title: String,
        description: String
    ) async throws {
        try await sendTicket(
            projectID: projectID,
            workingDirectory: workingDirectory,
            ticketID: ticketID,
            idempotencyKey: idempotencyKey,
            mode: mode,
            prompt: "\(title)\n\(description)"
        )
    }

    private func submitTask(
        projectID: UUID,
        taskID: UUID = UUID(),
        ticketID: UUID,
        kind: String,
        mode: TaskMode,
        idempotencyKey: String,
        workingDirectory: String,
        prompt: String?,
        payload: [String: String]
    ) async throws -> SubmitTaskResult {
        let request = SubmitTaskRequest(
            projectID: projectID.uuidString,
            taskID: taskID.uuidString,
            kind: kind,
            mode: mode.rawValue,
            ticketID: ticketID.uuidString,
            idempotencyKey: idempotencyKey,
            workingDirectory: workingDirectory,
            prompt: prompt,
            payload: payload.isEmpty ? nil : payload
        )

        let payloadLine = try Self.encodeLine(request)
        let responseObject: [String: Any]
        do {
            responseObject = try Self.sendRequest(
                payload: payloadLine,
                socketPath: supervisorSocketPath,
                receiveTimeout: 5,
                sendTimeout: 5
            )
        } catch let error as ManagerError {
            throw error
        } catch {
            throw ManagerError.supervisorUnavailable(error.localizedDescription)
        }

        guard let type = responseObject["type"] as? String else {
            throw ManagerError.invalidResponse("Missing response type.")
        }

        if type == "error" {
            let message = responseObject["message"] as? String ?? "Unknown supervisor error."
            throw ManagerError.requestFailed(message)
        }

        guard type == "submitTask.ok" else {
            throw ManagerError.invalidResponse("Unexpected submitTask response type '\(type)'.")
        }

        let resolvedTaskID: UUID = if let taskIDRaw = responseObject["taskID"] as? String, let parsed = UUID(uuidString: taskIDRaw) {
            parsed
        } else {
            taskID
        }
        let deduplicated = responseObject["deduplicated"] as? Bool ?? false
        return SubmitTaskResult(taskID: resolvedTaskID, deduplicated: deduplicated)
    }

    private func waitForTaskCompletion(taskID: UUID) async -> TaskTerminalResult {
        if let existing = taskTerminalResults[taskID] {
            return existing
        }

        return await withCheckedContinuation { continuation in
            var waiters = taskWaiters[taskID] ?? []
            waiters.append(continuation)
            taskWaiters[taskID] = waiters
        }
    }

    private func completeTask(_ result: TaskTerminalResult) {
        taskTerminalResults[result.taskID] = result
        let waiters = taskWaiters.removeValue(forKey: result.taskID) ?? []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func stopWorker(projectID: UUID) throws {
        userStoppedProjects.insert(projectID)

        let request = StopWorkerRequest(projectID: projectID.uuidString)
        let payload = try Self.encodeLine(request)

        let responseObject: [String: Any]
        do {
            responseObject = try Self.sendRequest(
                payload: payload,
                socketPath: supervisorSocketPath,
                receiveTimeout: 5,
                sendTimeout: 5
            )
        } catch let error as ManagerError {
            userStoppedProjects.remove(projectID)
            throw error
        } catch {
            userStoppedProjects.remove(projectID)
            throw ManagerError.supervisorUnavailable(error.localizedDescription)
        }

        guard let type = responseObject["type"] as? String else {
            userStoppedProjects.remove(projectID)
            throw ManagerError.invalidResponse("Missing response type.")
        }

        if type == "error" {
            let message = responseObject["message"] as? String ?? "Unknown supervisor error."
            userStoppedProjects.remove(projectID)
            throw ManagerError.requestFailed(message)
        }

        guard type == "stopWorker.ok" else {
            userStoppedProjects.remove(projectID)
            throw ManagerError.invalidResponse("Unexpected stopWorker response type '\(type)'.")
        }

        // stopWorker is idempotent; update the local status immediately in case no worker was running.
        setStatus(.stopped, for: projectID)
    }

    private func ensureProjectSubscription(projectID: UUID) {
        if let existing = subscriptionTasks[projectID], existing.isCancelled == false {
            return
        }

        let socketPath = supervisorSocketPath
        subscriptionTasks[projectID] = Task.detached { [weak self, socketPath] in
            await Self.runProjectSubscriptionLoop(projectID: projectID, socketPath: socketPath) { [weak self] in
                self
            }
        }
    }

    private func resumeProjectSubscriptionsForActiveTasks() async {
        if let snapshots = try? fetchWorkerSnapshots(projectID: nil) {
            applyWorkerSnapshots(snapshots)
        }

        guard let activeTaskSnapshots = try? fetchActiveTaskSnapshots() else { return }
        for snapshot in activeTaskSnapshots {
            ensureProjectSubscription(projectID: snapshot.projectID)
        }
    }

    private func consumeSupervisorLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        trackEventCursorIfNeeded(payload: payload)

        guard let type = payload["type"] as? String else { return }

        switch type {
        case "task.accepted":
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            if
                let requestID = parseUUID(payload["requestID"] as? String),
                let projectID = parseUUID(payload["projectID"] as? String)
            {
                requestsUsingTaskEvents.insert(requestID)
                requestToTicket[requestID] = ticketID
                requestToProject[requestID] = projectID
                setStatus(.running, for: projectID)
            }
            continuation.yield(.ticketStarted(ticketID: ticketID))

        case "task.output":
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            let line = payload["text"] as? String ?? ""
            continuation.yield(.ticketOutput(ticketID: ticketID, line: line))

        case "task.failed":
            let summary = payload["summary"] as? String ?? payload["message"] as? String
            if let requestID = parseUUID(payload["requestID"] as? String) {
                requestsUsingTaskEvents.remove(requestID)
                completeTask(
                    TaskTerminalResult(
                        taskID: requestID,
                        success: false,
                        summary: summary
                    )
                )
            }
            if let ticketID = resolveTicketID(payload: payload) {
                continuation.yield(.ticketCompleted(ticketID: ticketID, success: false, summary: summary))
            }
            clearRequestMappings(payload: payload)

        case "task.completed":
            let summary = payload["summary"] as? String
            if let requestID = parseUUID(payload["requestID"] as? String) {
                requestsUsingTaskEvents.remove(requestID)
                completeTask(
                    TaskTerminalResult(
                        taskID: requestID,
                        success: true,
                        summary: summary
                    )
                )
            }
            if let ticketID = resolveTicketID(payload: payload) {
                continuation.yield(.ticketCompleted(ticketID: ticketID, success: true, summary: summary))
            }
            clearRequestMappings(payload: payload)

        case "worker.started":
            guard let projectID = parseUUID(payload["projectID"] as? String) else { return }
            setStatus(.running, for: projectID)

        case "worker.exited":
            guard let projectID = parseUUID(payload["projectID"] as? String) else { return }
            if userStoppedProjects.remove(projectID) != nil {
                setStatus(.stopped, for: projectID)
            } else if let message = payload["message"] as? String {
                setStatus(.error(message), for: projectID)
            } else {
                setStatus(.stopped, for: projectID)
            }

        case "ticket.started":
            if shouldIgnoreLegacyTicketEvent(payload: payload) { return }
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            if
                let requestID = parseUUID(payload["requestID"] as? String),
                let projectID = parseUUID(payload["projectID"] as? String)
            {
                requestToTicket[requestID] = ticketID
                requestToProject[requestID] = projectID
                setStatus(.running, for: projectID)
            }
            continuation.yield(.ticketStarted(ticketID: ticketID))

        case "ticket.output":
            if shouldIgnoreLegacyTicketEvent(payload: payload) { return }
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            let line = payload["text"] as? String ?? ""
            continuation.yield(.ticketOutput(ticketID: ticketID, line: line))

        case "ticket.error":
            if shouldIgnoreLegacyTicketEvent(payload: payload) { return }
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            let message = payload["message"] as? String ?? "Unknown ticket error"
            continuation.yield(.ticketError(ticketID: ticketID, message: message))

        case "ticket.completed":
            if shouldIgnoreLegacyTicketEvent(payload: payload) { return }
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            let success = payload["success"] as? Bool ?? false
            let summary = payload["summary"] as? String
            continuation.yield(.ticketCompleted(ticketID: ticketID, success: success, summary: summary))
            clearRequestMappings(payload: payload)

        default:
            break
        }
    }

    private func handleSubscriptionDisconnected(projectID: UUID) {
        // Keep current status unchanged; reconnect loop will restore streaming on success.
        subscriptionTasks.removeValue(forKey: projectID)
    }

    private func trackEventCursorIfNeeded(payload: [String: Any]) {
        guard
            let projectID = parseUUID(payload["projectID"] as? String),
            let eventIDValue = payload["eventID"]
        else {
            return
        }

        let eventID: Int64
        if let numeric = eventIDValue as? NSNumber {
            eventID = numeric.int64Value
        } else if let text = eventIDValue as? String, let parsed = Int64(text) {
            eventID = parsed
        } else {
            return
        }

        let previous = cursorByProject[projectID] ?? 0
        if eventID <= previous {
            return
        }

        cursorByProject[projectID] = eventID
        persistCursorStore()
        sendAck(projectID: projectID, upToEventID: eventID)
    }

    private func applyWorkerSnapshots(_ snapshots: [WorkerSnapshot]) {
        for snapshot in snapshots {
            if snapshot.isRunning {
                setStatus(.running, for: snapshot.projectID)
            }

            var startedTickets: Set<UUID> = []
            for activeRequest in snapshot.activeRequests {
                if let ticketID = activeRequest.ticketID {
                    requestToTicket[activeRequest.requestID] = ticketID
                    requestToProject[activeRequest.requestID] = snapshot.projectID
                    startedTickets.insert(ticketID)
                }
            }

            for ticketID in startedTickets.sorted(by: { $0.uuidString < $1.uuidString }) {
                continuation.yield(.ticketStarted(ticketID: ticketID))
            }
        }
    }

    private func fetchActiveTaskSnapshots() throws -> [ActiveTaskSnapshot] {
        let payload = try Self.encodeLine(ListActiveTasksRequest())
        let responseObject = try Self.sendRequest(
            payload: payload,
            socketPath: supervisorSocketPath,
            receiveTimeout: 5,
            sendTimeout: 5
        )

        guard let type = responseObject["type"] as? String, type == "listActiveTasks.ok" else {
            throw ManagerError.invalidResponse("Unexpected listActiveTasks response.")
        }
        guard let tasks = responseObject["tasks"] as? [[String: Any]] else {
            throw ManagerError.invalidResponse("listActiveTasks response missing tasks list.")
        }

        var projects: Set<UUID> = []
        for task in tasks {
            guard let projectIDRaw = task["projectID"] as? String, let projectID = UUID(uuidString: projectIDRaw) else {
                continue
            }
            projects.insert(projectID)
        }

        return projects.sorted { $0.uuidString < $1.uuidString }.map(ActiveTaskSnapshot.init(projectID:))
    }

    private func fetchTaskStatus(taskID: UUID) throws -> TaskStatusSnapshot? {
        let request = TaskStatusRequest(taskID: taskID.uuidString, projectID: nil)
        let payload = try Self.encodeLine(request)
        let responseObject = try Self.sendRequest(
            payload: payload,
            socketPath: supervisorSocketPath,
            receiveTimeout: 5,
            sendTimeout: 5
        )

        guard let type = responseObject["type"] as? String, type == "taskStatus.ok" else {
            throw ManagerError.invalidResponse("Unexpected taskStatus response.")
        }
        guard let tasks = responseObject["tasks"] as? [[String: Any]] else {
            throw ManagerError.invalidResponse("taskStatus response missing tasks list.")
        }

        for task in tasks {
            guard let taskIDRaw = task["taskID"] as? String, let currentTaskID = UUID(uuidString: taskIDRaw) else {
                continue
            }
            guard currentTaskID == taskID else { continue }
            let state = task["state"] as? String ?? ""
            let success = task["success"] as? Bool
            let summary = task["summary"] as? String
            return TaskStatusSnapshot(taskID: taskID, state: state, success: success, summary: summary)
        }

        return nil
    }

    private func sendAck(projectID: UUID, upToEventID: Int64) {
        let request = AckRequest(projectID: projectID.uuidString, upToEventID: upToEventID)
        guard let payload = try? Self.encodeLine(request) else { return }
        _ = try? Self.sendRequest(
            payload: payload,
            socketPath: supervisorSocketPath,
            receiveTimeout: 5,
            sendTimeout: 5
        )
    }

    private func fetchWorkerSnapshots(projectID: UUID?) throws -> [WorkerSnapshot] {
        let request = WorkerStatusRequest(projectID: projectID?.uuidString)
        let payload = try Self.encodeLine(request)
        let responseObject = try Self.sendRequest(
            payload: payload,
            socketPath: supervisorSocketPath,
            receiveTimeout: 5,
            sendTimeout: 5
        )

        guard let type = responseObject["type"] as? String, type == "workerStatus.ok" else {
            throw ManagerError.invalidResponse("Unexpected workerStatus response.")
        }

        guard let workerArray = responseObject["workers"] as? [[String: Any]] else {
            throw ManagerError.invalidResponse("workerStatus response missing worker list.")
        }

        return workerArray.compactMap { worker -> WorkerSnapshot? in
            guard
                let projectIDRaw = worker["projectID"] as? String,
                let resolvedProjectID = UUID(uuidString: projectIDRaw)
            else {
                return nil
            }

            let isRunning = worker["isRunning"] as? Bool ?? false
            let activeRequests = (worker["activeRequests"] as? [[String: Any]] ?? []).compactMap { request -> WorkerSnapshot.ActiveRequest? in
                guard
                    let requestIDRaw = request["requestID"] as? String,
                    let requestID = UUID(uuidString: requestIDRaw),
                    let modeRaw = request["mode"] as? String,
                    let mode = TaskMode(rawValue: modeRaw)
                else {
                    return nil
                }
                let ticketID = parseUUID(request["ticketID"] as? String)
                return WorkerSnapshot.ActiveRequest(requestID: requestID, ticketID: ticketID, mode: mode)
            }
            return WorkerSnapshot(
                projectID: resolvedProjectID,
                isRunning: isRunning,
                activeRequests: activeRequests
            )
        }
    }

    private func resolveTicketID(payload: [String: Any]) -> UUID? {
        if let ticketID = parseUUID(payload["ticketID"] as? String) {
            return ticketID
        }
        if
            let requestID = parseUUID(payload["requestID"] as? String),
            let ticketID = requestToTicket[requestID]
        {
            return ticketID
        }
        return nil
    }

    private func clearRequestMappings(payload: [String: Any]) {
        guard let requestID = parseUUID(payload["requestID"] as? String) else { return }
        requestsUsingTaskEvents.remove(requestID)
        requestToTicket.removeValue(forKey: requestID)
        requestToProject.removeValue(forKey: requestID)
    }

    private func shouldIgnoreLegacyTicketEvent(payload: [String: Any]) -> Bool {
        guard let requestID = parseUUID(payload["requestID"] as? String) else { return false }
        return requestsUsingTaskEvents.contains(requestID)
    }

    private func setStatus(_ status: CodexProjectStatus, for projectID: UUID) {
        statuses[projectID] = status
        continuation.yield(.statusChanged(projectID: projectID, status: status))
    }

    private func persistCursorStore() {
        Self.persistCursorStore(path: cursorStorePath, cursors: cursorByProject)
    }

    private func parseUUID(_ rawValue: String?) -> UUID? {
        guard let rawValue else { return nil }
        return UUID(uuidString: rawValue)
    }

    private func resolveWorkingDirectory(_ workingDirectory: String?) throws -> String {
        guard let workingDirectory else {
            throw ManagerError.missingWorkingDirectory
        }

        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ManagerError.missingWorkingDirectory
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory)

        guard exists, isDirectory.boolValue else {
            throw ManagerError.invalidWorkingDirectory(expanded)
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private nonisolated static func runProjectSubscriptionLoop(
        projectID: UUID,
        socketPath: String,
        owner: @escaping @Sendable () -> CodexManager?
    ) async {
        var reconnectDelay: UInt64 = 1_000_000_000

        while Task.isCancelled == false {
            guard owner() != nil else { return }

            let fd: Int32
            do {
                fd = try connect(to: socketPath, receiveTimeout: 30, sendTimeout: 5)
            } catch {
                await owner()?.handleSubscriptionDisconnected(projectID: projectID)
                try? await Task.sleep(nanoseconds: reconnectDelay)
                reconnectDelay = min(reconnectDelay * 2, 10_000_000_000)
                continue
            }

            defer { Darwin.close(fd) }

            do {
                let fromEventID = await owner()?.cursorByProject[projectID].map { $0 + 1 }
                let subscribePayload = try encodeLine(
                    SubscribeRequest(projectID: projectID.uuidString, fromEventID: fromEventID)
                )
                guard writeAll(subscribePayload, to: fd) else {
                    throw ManagerError.supervisorUnavailable("Failed to write subscribe request.")
                }

                var streamBuffer = Data()
                guard
                    case let .line(responseLine) = readBufferedLine(from: fd, buffer: &streamBuffer),
                    let responseData = responseLine.data(using: .utf8)
                else {
                    throw ManagerError.supervisorUnavailable("Failed to read subscribe response.")
                }
                guard
                    let responseObject = try (JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
                    let responseType = responseObject["type"] as? String,
                    responseType == "subscribe.ok"
                else {
                    throw ManagerError.invalidResponse("Supervisor rejected subscribe request.")
                }

                reconnectDelay = 1_000_000_000

                subscriptionReadLoop: while Task.isCancelled == false {
                    switch readBufferedLine(from: fd, buffer: &streamBuffer) {
                    case let .line(line):
                        guard let currentOwner = owner() else { return }
                        await currentOwner.consumeSupervisorLine(line)

                    case .timeout:
                        continue

                    case .eof, .error:
                        break subscriptionReadLoop
                    }
                }
            } catch {
                await owner()?.handleSubscriptionDisconnected(projectID: projectID)
                try? await Task.sleep(nanoseconds: reconnectDelay)
                reconnectDelay = min(reconnectDelay * 2, 10_000_000_000)
                continue
            }

            await owner()?.handleSubscriptionDisconnected(projectID: projectID)
            try? await Task.sleep(nanoseconds: reconnectDelay)
            reconnectDelay = min(reconnectDelay * 2, 10_000_000_000)
        }
    }

    private nonisolated static func sendRequest(
        payload: Data,
        socketPath: String,
        receiveTimeout: Int,
        sendTimeout: Int
    ) throws -> [String: Any] {
        let fd = try connect(to: socketPath, receiveTimeout: receiveTimeout, sendTimeout: sendTimeout)
        defer { Darwin.close(fd) }

        guard writeAll(payload, to: fd) else {
            throw ManagerError.supervisorUnavailable("Failed to write request.")
        }

        var streamBuffer = Data()
        guard
            case let .line(responseLine) = readBufferedLine(from: fd, buffer: &streamBuffer),
            let responseData = responseLine.data(using: .utf8)
        else {
            throw ManagerError.supervisorUnavailable("Failed to read response.")
        }

        guard let responseObject = try (JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else {
            throw ManagerError.invalidResponse("Response was not a JSON object.")
        }

        return responseObject
    }

    private nonisolated static func encodeLine(_ value: some Encodable) throws -> Data {
        var payload = try JSONEncoder().encode(value)
        payload.append(0x0A)
        return payload
    }

    private nonisolated static func connect(to socketPath: String, receiveTimeout: Int, sendTimeout: Int) throws -> Int32 {
        let normalizedSocketPath = expandPath(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ManagerError.supervisorUnavailable("Failed to open socket: \(String(cString: strerror(errno))).")
        }

        setNoSigPipe(fd: fd)
        setTimeout(fd: fd, option: SO_RCVTIMEO, seconds: receiveTimeout)
        setTimeout(fd: fd, option: SO_SNDTIMEO, seconds: sendTimeout)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let socketPathBytes = normalizedSocketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPathBytes.count <= maxPathLength else {
            Darwin.close(fd)
            throw ManagerError.supervisorUnavailable("Socket path is too long: \(normalizedSocketPath)")
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            socketPathBytes.withUnsafeBytes { sourceBuffer in
                if let destination = rawBuffer.baseAddress, let source = sourceBuffer.baseAddress {
                    memcpy(destination, source, socketPathBytes.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ManagerError.supervisorUnavailable(message)
        }

        return fd
    }

    private nonisolated static func readBufferedLine(
        from fd: Int32,
        buffer: inout Data,
        maxBytes: Int = controlProtocolMaxLineBytes
    ) -> SocketReadResult {
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var candidate = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            if candidate.last == 0x0D {
                candidate = candidate.dropLast()
            }
            return .line(String(decoding: candidate, as: UTF8.self))
        }

        var chunk = [UInt8](repeating: 0, count: 1_024)
        let count = Darwin.read(fd, &chunk, chunk.count)

        if count > 0 {
            buffer.append(chunk, count: count)
            if buffer.count > maxBytes {
                return .error
            }
            return readBufferedLine(from: fd, buffer: &buffer, maxBytes: maxBytes)
        }

        if count == 0 {
            return .eof
        }

        if errno == EINTR {
            return readBufferedLine(from: fd, buffer: &buffer, maxBytes: maxBytes)
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
            return .timeout
        }

        return .error
    }

    private nonisolated static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        var bytesWritten = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let rawBaseAddress = rawBuffer.baseAddress else { return false }

            while bytesWritten < data.count {
                let remaining = data.count - bytesWritten
                let currentAddress = rawBaseAddress.advanced(by: bytesWritten)
                let result = Darwin.write(fd, currentAddress, remaining)
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

    private nonisolated static func setTimeout(fd: Int32, option: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, option, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private nonisolated static func setNoSigPipe(fd: Int32) {
        #if os(macOS)
            var enabled: Int32 = 1
            _ = withUnsafePointer(to: &enabled) { pointer in
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
            }
        #endif
    }

    private nonisolated static func expandPath(_ path: String) -> String {
        let expandedTilde = (path as NSString).expandingTildeInPath
        let homeDirectory = NSHomeDirectory()
        let expandedEnv = expandedTilde
            .replacingOccurrences(of: "${HOME}", with: homeDirectory)
            .replacingOccurrences(of: "$HOME", with: homeDirectory)
        return URL(fileURLWithPath: expandedEnv).standardizedFileURL.path
    }

    private nonisolated static func loadCursorStore(path: String) -> [UUID: Int64] {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }

        var result: [UUID: Int64] = [:]
        for (projectIDRaw, cursor) in decoded {
            guard let projectID = UUID(uuidString: projectIDRaw) else { continue }
            result[projectID] = cursor
        }
        return result
    }

    private nonisolated static func persistCursorStore(path: String, cursors: [UUID: Int64]) {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoded = Dictionary(uniqueKeysWithValues: cursors.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private enum SocketReadResult {
        case line(String)
        case timeout
        case eof
        case error
    }
}

extension CodexManager: LoopTaskExecutor {}

struct CodexTicketOutputSnapshot {
    let text: String
    let isTruncated: Bool
}

enum TicketStatusAttentionIndicator: Equatable {
    case error
    case needsResponse
}

@MainActor
@Observable
final class CodexViewModel {
    private static let statusLogger = Logger(
        subsystem: "TicketParty",
        category: "CodexViewModel.TicketStatus"
    )

    private let manager: CodexManager
    private let loopManager: TicketLoopManager
    private let supervisorHealthChecker: CodexSupervisorHealthChecker
    private let transcriptStore: TicketTranscriptStore
    private let conversationStore: TicketConversationStore
    private let debugAssertionHandler: (String, StaticString, UInt) -> Void
    private var modelContext: ModelContext?
    private let minSpinnerDuration: Duration = .seconds(1)
    private let replayWindowCount = TicketConversationStore.defaultWindowCount
    private let replaySummaryLimit = TicketConversationStore.defaultMaxSummaryChars
    private var eventTask: Task<Void, Never>?
    private var loopEventTask: Task<Void, Never>?
    private var supervisorHealthTask: Task<Void, Never>?

    var projectStatuses: [UUID: CodexProjectStatus] = [:]
    var loopStates: [UUID: LoopRunState] = [:]
    var loopMessages: [UUID: String] = [:]
    var ticketOutput: [UUID: String] = [:]
    var ticketErrors: [UUID: String] = [:]
    var ticketIsSending: [UUID: Bool] = [:]
    var activeRunByTicketID: [UUID: UUID] = [:]
    var activeAssistantMessageByTicketID: [UUID: UUID] = [:]
    var ticketConversationMessages: [UUID: [TicketConversationMessageRecord]] = [:]
    var ticketConversationModes: [UUID: TicketConversationMode] = [:]
    var ticketSendingModes: [UUID: TicketConversationMode] = [:]
    var ticketConversationLoading: [UUID: Bool] = [:]
    var supervisorHealth: CodexSupervisorHealthStatus = .notRunning

    init(
        manager: CodexManager = CodexManager(),
        supervisorHealthChecker: CodexSupervisorHealthChecker = CodexSupervisorHealthChecker(),
        transcriptStore: TicketTranscriptStore = TicketTranscriptStore(),
        conversationStore: TicketConversationStore = TicketConversationStore(),
        debugAssertionHandler: @escaping (String, StaticString, UInt) -> Void = { message, file, line in
            assertionFailure(message, file: file, line: line)
        },
        startBackgroundTasks: Bool = true
    ) {
        self.manager = manager
        loopManager = TicketLoopManager(executor: manager)
        self.supervisorHealthChecker = supervisorHealthChecker
        self.transcriptStore = transcriptStore
        self.conversationStore = conversationStore
        self.debugAssertionHandler = debugAssertionHandler

        if startBackgroundTasks {
            do {
                try transcriptStore.markInterruptedRunsAsFailed(now: .now)
            } catch {
                NSLog("Ticket transcript recovery failed: %@", error.localizedDescription)
            }

            eventTask = Task { [manager, weak self] in
                for await event in manager.events {
                    guard let self else { return }
                    await MainActor.run {
                        self.consume(event)
                    }
                }
            }

            loopEventTask = Task { [loopManager, weak self] in
                for await event in loopManager.events {
                    guard let self else { return }
                    await MainActor.run {
                        self.consumeLoopEvent(event)
                    }
                }
            }

            supervisorHealthTask = Task { [weak self] in
                guard let self else { return }
                await refreshSupervisorHealth()
                while Task.isCancelled == false {
                    try? await Task.sleep(for: .seconds(5))
                    await refreshSupervisorHealth()
                }
            }
        }
    }

    func loadConversation(ticketID: UUID) {
        ticketConversationLoading[ticketID] = true
        defer { ticketConversationLoading[ticketID] = false }

        do {
            _ = try conversationStore.ensureThread(ticketID: ticketID)
            ticketConversationModes[ticketID] = try conversationStore.mode(ticketID: ticketID)
            ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)
        } catch {
            ticketErrors[ticketID] = "Failed to load conversation: \(error.localizedDescription)"
        }
    }

    func conversationMode(for ticketID: UUID) -> TicketConversationMode {
        ticketConversationModes[ticketID] ?? .plan
    }

    func conversationMessages(for ticketID: UUID) -> [TicketConversationMessageRecord] {
        ticketConversationMessages[ticketID, default: []]
    }

    func inFlightConversationMode(for ticketID: UUID) -> TicketConversationMode? {
        guard ticketIsSending[ticketID] == true else { return nil }
        return ticketSendingModes[ticketID] ?? ticketConversationModes[ticketID] ?? .plan
    }

    func statusAttentionIndicator(for ticketID: UUID) -> TicketStatusAttentionIndicator? {
        if let error = ticketErrors[ticketID]?.trimmingCharacters(in: .whitespacesAndNewlines), error.isEmpty == false {
            return .error
        }

        guard
            let latestAssistantMessage = ticketConversationMessages[ticketID]?
                .last(where: { message in
                    message.role == .assistant &&
                        message.status != .pending &&
                        message.status != .streaming
                })
        else {
            return nil
        }

        return latestAssistantMessage.requiresResponse ? .needsResponse : nil
    }

    func setConversationMode(ticketID: UUID, mode: TicketConversationMode) {
        do {
            try conversationStore.setMode(ticketID: ticketID, mode: mode)
            ticketConversationModes[ticketID] = mode
            if ticketIsSending[ticketID] == true {
                ticketSendingModes[ticketID] = mode
            }
        } catch {
            ticketErrors[ticketID] = "Failed to set mode: \(error.localizedDescription)"
        }
    }

    func send(ticket: Ticket, project: Project) async {
        let summary = """
        Please continue this ticket conversation.
        Ticket: \(ticket.title)
        Description: \(ticket.ticketDescription.isEmpty ? "(none)" : ticket.ticketDescription)
        """
        await sendMessage(ticket: ticket, project: project, text: summary)
    }

    func sendMessage(ticket: Ticket, project: Project, text: String) async {
        let projectID = project.id
        let ticketID = ticket.id
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard ticketIsSending[ticketID] != true else { return }

        let clock = ContinuousClock()
        let start = clock.now

        let runID: UUID
        let prompt: String
        let mode: TicketConversationMode

        do {
            _ = try conversationStore.ensureThread(ticketID: ticketID)
            _ = try conversationStore.appendUserMessage(ticketID: ticketID, text: trimmed)
            runID = try transcriptStore.startRun(projectID: projectID, ticketID: ticketID, requestID: nil)
            activeRunByTicketID[ticketID] = runID
            ticketOutput[ticketID] = ""

            let assistant = try conversationStore.beginAssistantMessage(ticketID: ticketID, runID: runID)
            activeAssistantMessageByTicketID[ticketID] = assistant.id
            let replay = try conversationStore.replayBundle(
                ticketID: ticketID,
                windowCount: replayWindowCount,
                maxSummaryChars: replaySummaryLimit
            )
            mode = replay.mode
            ticketConversationModes[ticketID] = replay.mode
            ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)
            prompt = conversationPrompt(
                ticket: ticket,
                mode: replay.mode,
                summary: replay.summary,
                messages: replay.messages
            )
            ticketSendingModes[ticketID] = mode
        } catch {
            ticketErrors[ticketID] = "Failed to prepare message: \(error.localizedDescription)"
            return
        }

        ticketErrors[ticketID] = nil
        setTicketSending(true, for: ticketID)

        await Task.yield()

        do {
            let idempotencyKey = CodexManager.ticketTaskIdempotencyKey(ticketID: ticketID, runID: runID)
            try await manager.sendTicket(
                projectID: projectID,
                workingDirectory: project.workingDirectory,
                ticketID: ticketID,
                idempotencyKey: idempotencyKey,
                mode: mode,
                prompt: prompt
            )
        } catch {
            ticketErrors[ticketID] = error.localizedDescription
            do {
                try transcriptStore.completeRun(runID: runID, success: false, summary: error.localizedDescription)
            } catch {
                NSLog("Failed to finalize transcript for send error: %@", error.localizedDescription)
            }
            do {
                try conversationStore.completeAssistantMessage(
                    ticketID: ticketID,
                    success: false,
                    errorSummary: error.localizedDescription
                )
                ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)
            } catch {
                NSLog("Failed to finalize assistant message after send error: %@", error.localizedDescription)
            }
            activeRunByTicketID.removeValue(forKey: ticketID)
            activeAssistantMessageByTicketID.removeValue(forKey: ticketID)

            let elapsed = start.duration(to: clock.now)
            if elapsed < minSpinnerDuration {
                try? await Task.sleep(for: minSpinnerDuration - elapsed)
            }
            setTicketSending(false, for: ticketID)
        }
    }

    func startImplementation(ticket: Ticket, project: Project) async {
        let ticketID = ticket.id

        do {
            _ = try conversationStore.ensureThread(ticketID: ticketID)
            let existingMode = try conversationStore.mode(ticketID: ticketID)
            guard existingMode == .plan else { return }

            try conversationStore.setMode(ticketID: ticketID, mode: .implement)
            _ = try conversationStore.appendSystemMessage(
                ticketID: ticketID,
                text: "Mode switched to implement."
            )
            let replay = try conversationStore.replayBundle(
                ticketID: ticketID,
                windowCount: replayWindowCount,
                maxSummaryChars: replaySummaryLimit
            )
            setTicketStatus(ticketID: ticketID, status: .inProgress)
            ticketConversationModes[ticketID] = .implement
            ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)

            let handoff = synthesizedImplementationHandoff(summary: replay.summary, messages: replay.messages)
            await sendMessage(ticket: ticket, project: project, text: handoff)
        } catch {
            ticketErrors[ticketID] = "Failed to start implementation: \(error.localizedDescription)"
        }
    }

    func stop(ticket: Ticket, project: Project) async {
        let ticketID = ticket.id

        await manager.cancelTicketTasks(projectID: project.id, ticketID: ticketID)
        if let runID = activeRunByTicketID.removeValue(forKey: ticketID) {
            try? transcriptStore.completeRun(runID: runID, success: false, summary: "Cancelled by user.")
        }
        if activeAssistantMessageByTicketID[ticketID] != nil {
            do {
                try conversationStore.completeAssistantMessage(
                    ticketID: ticketID,
                    success: false,
                    errorSummary: "Cancelled by user."
                )
                ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)
            } catch {
                NSLog("Failed to mark assistant message as cancelled: %@", error.localizedDescription)
            }
        }
        activeAssistantMessageByTicketID.removeValue(forKey: ticketID)
        setTicketSending(false, for: ticketID)
    }

    func startLoop(project: Project, tickets: [Ticket]) async {
        do {
            let workingDirectory = try resolveProjectWorkingDirectory(project)
            let loopTickets = loopTicketItems(from: tickets, projectID: project.id)
            try await loopManager.start(
                projectID: project.id,
                workingDirectory: workingDirectory,
                tickets: loopTickets
            )
            await markCurrentLoopTicketAsInProgress(projectID: project.id, fallbackTickets: loopTickets)
            loopMessages[project.id] = nil
        } catch {
            loopMessages[project.id] = error.localizedDescription
        }
    }

    func pauseLoop(projectID: UUID) async {
        await loopManager.pause(projectID: projectID)
    }

    func resumeLoop(project: Project, tickets: [Ticket]) async {
        do {
            let workingDirectory = try resolveProjectWorkingDirectory(project)
            let loopTickets = loopTicketItems(from: tickets, projectID: project.id)
            try await loopManager.resume(
                projectID: project.id,
                workingDirectory: workingDirectory,
                fallbackTickets: loopTickets
            )
            await markCurrentLoopTicketAsInProgress(projectID: project.id, fallbackTickets: loopTickets)
            loopMessages[project.id] = nil
        } catch {
            loopMessages[project.id] = error.localizedDescription
        }
    }

    func cancelLoop(projectID: UUID) async {
        await loopManager.cancel(projectID: projectID)
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func status(for projectID: UUID) -> CodexProjectStatus {
        projectStatuses[projectID] ?? .stopped
    }

    func loopState(for projectID: UUID) -> LoopRunState {
        loopStates[projectID] ?? .idle
    }

    func output(for ticketID: UUID) -> String {
        ticketOutput[ticketID, default: ""]
    }

    func outputSnapshot(for ticketID: UUID, maxBytes: Int?) -> CodexTicketOutputSnapshot {
        if activeRunByTicketID[ticketID] != nil {
            return CodexTicketOutputSnapshot(text: ticketOutput[ticketID, default: ""], isTruncated: false)
        }

        do {
            guard let run = try transcriptStore.latestRun(ticketID: ticketID) else {
                return CodexTicketOutputSnapshot(text: ticketOutput[ticketID, default: ""], isTruncated: false)
            }
            let text = try transcriptStore.loadTranscript(runID: run.id, maxBytes: maxBytes)
            let isTruncated = if let maxBytes, maxBytes > 0 {
                run.byteCount > Int64(maxBytes)
            } else {
                false
            }
            return CodexTicketOutputSnapshot(text: text, isTruncated: isTruncated)
        } catch {
            return CodexTicketOutputSnapshot(text: ticketOutput[ticketID, default: ""], isTruncated: false)
        }
    }

    func refreshSupervisorHealth() async {
        supervisorHealth = await supervisorHealthChecker.check()
    }

    private func consume(_ event: CodexManager.Event) {
        switch event {
        case let .statusChanged(projectID, status):
            projectStatuses[projectID] = status

        case let .ticketStarted(ticketID):
            if ticketSendingModes[ticketID] == nil {
                ticketSendingModes[ticketID] = resolvedConversationModeForTicketStart(ticketID: ticketID)
            }
            setTicketSending(true, for: ticketID)

        case let .ticketOutput(ticketID, line):
            var updatedOutput = ticketOutput[ticketID, default: ""]
            if updatedOutput.isEmpty {
                updatedOutput = line
            } else {
                updatedOutput += "\n"
                updatedOutput += line
            }
            ticketOutput[ticketID] = updatedOutput

            if let runID = activeRunByTicketID[ticketID] {
                do {
                    try transcriptStore.appendOutput(runID: runID, line: line)
                } catch {
                    NSLog("Failed to append transcript output: %@", error.localizedDescription)
                }
            }

            if activeAssistantMessageByTicketID[ticketID] != nil {
                do {
                    try conversationStore.appendAssistantOutput(ticketID: ticketID, line: line)
                    ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)
                } catch {
                    NSLog("Failed to append assistant streaming output: %@", error.localizedDescription)
                }
            }

            if let completion = agentTicketCompletion(from: line) {
                applyTicketCompletion(ticketID: ticketID, success: completion.success, summary: completion.summary)
            }

        case let .ticketError(ticketID, message):
            ticketErrors[ticketID] = message
            if let runID = activeRunByTicketID[ticketID] {
                do {
                    try transcriptStore.appendError(runID: runID, message: message)
                } catch {
                    NSLog("Failed to append transcript error: %@", error.localizedDescription)
                }
            }

            if activeAssistantMessageByTicketID[ticketID] != nil {
                do {
                    try conversationStore.appendAssistantOutput(ticketID: ticketID, line: "[ERROR] \(message)")
                    ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)
                } catch {
                    NSLog("Failed to append assistant streaming error: %@", error.localizedDescription)
                }
            }

        case let .ticketCompleted(ticketID, success, summary):
            applyTicketCompletion(ticketID: ticketID, success: success, summary: summary)
        }
    }

    private func consumeLoopEvent(_ event: TicketLoopManager.Event) {
        switch event {
        case let .stateChanged(projectID, state):
            loopStates[projectID] = state
            if case let .failed(failure, _) = state {
                loopMessages[projectID] = failure.message
            } else if case .completed = state {
                loopMessages[projectID] = nil
            }

        case let .ticketStarted(_, ticketID, _, _):
            ticketSendingModes[ticketID] = .implement
            setTicketSending(true, for: ticketID)
            setTicketStatus(ticketID: ticketID, status: .inProgress)

        case let .ticketFinished(_, ticketID, success, message):
            if success {
                ticketErrors[ticketID] = nil
            } else if let message, message.isEmpty == false {
                ticketErrors[ticketID] = message
            }
            updateTicketStatusAfterCompletion(
                ticketID: ticketID,
                success: success,
                mode: .implement
            )
            setTicketSending(false, for: ticketID)

        case .cleanupStepStarted:
            break

        case let .cleanupStepFinished(_, ticketID, _, success, message):
            if success == false, let message, message.isEmpty == false {
                ticketErrors[ticketID] = message
            }
        }
    }

    private func applyTicketCompletion(ticketID: UUID, success: Bool, summary: String?) {
        let completionMode = completionModeForTicketCompletion(ticketID: ticketID)

        if let runID = activeRunByTicketID.removeValue(forKey: ticketID) {
            do {
                try transcriptStore.completeRun(runID: runID, success: success, summary: summary)
            } catch {
                NSLog("Failed to complete transcript run: %@", error.localizedDescription)
            }
        }

        if activeAssistantMessageByTicketID[ticketID] != nil {
            do {
                try conversationStore.completeAssistantMessage(ticketID: ticketID, success: success, errorSummary: summary)
                ticketConversationMessages[ticketID] = try conversationStore.messages(ticketID: ticketID)
            } catch {
                NSLog("Failed to complete assistant message: %@", error.localizedDescription)
            }
        }
        activeAssistantMessageByTicketID.removeValue(forKey: ticketID)

        if success {
            ticketErrors[ticketID] = nil
        } else if let summary, summary.isEmpty == false {
            ticketErrors[ticketID] = summary
        }
        updateTicketStatusAfterCompletion(
            ticketID: ticketID,
            success: success,
            mode: completionMode
        )
        setTicketSending(false, for: ticketID)
    }

    func updateTicketStatusAfterCompletion(
        ticketID: UUID,
        success: Bool,
        mode: TicketConversationMode?
    ) {
        guard success, mode == .implement else {
            return
        }
        setTicketStatus(ticketID: ticketID, status: .review)
    }

    private func completionModeForTicketCompletion(ticketID: UUID) -> TicketConversationMode? {
        if let mode = ticketSendingModes[ticketID] {
            return mode
        }
        if let mode = ticketConversationModes[ticketID] {
            return mode
        }
        return try? conversationStore.mode(ticketID: ticketID)
    }

    private func agentTicketCompletion(from line: String) -> (success: Bool, summary: String?)? {
        guard line.contains("ticket.completed") else {
            return nil
        }

        guard let payload = parseJSONObject(from: line) else {
            // If the line is unstructured text but clearly includes the completion marker,
            // still treat it as a terminal success signal.
            return (true, nil)
        }

        guard let completionPayload = findTicketCompletedPayload(in: payload) else {
            return nil
        }

        let success = completionPayload["success"] as? Bool ?? true
        let summary = completionPayload["summary"] as? String
            ?? completionPayload["error"] as? String
            ?? completionPayload["message"] as? String
        return (success, summary)
    }

    private func parseJSONObject(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = decodeJSONObject(from: trimmed) {
            return decoded
        }

        let payloadLine: String
        if trimmed.hasPrefix("data:") {
            payloadLine = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let decoded = decodeJSONObject(from: payloadLine) {
                return decoded
            }
        } else {
            payloadLine = trimmed
        }

        guard
            let start = payloadLine.firstIndex(of: "{"),
            let end = payloadLine.lastIndex(of: "}"),
            start <= end
        else {
            return nil
        }

        let slice = payloadLine[start ... end]
        return decodeJSONObject(from: String(slice))
    }

    private func decodeJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private func findTicketCompletedPayload(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String, type == "ticket.completed" {
                return dictionary
            }

            for nestedValue in dictionary.values {
                if let match = findTicketCompletedPayload(in: nestedValue) {
                    return match
                }
            }
            return nil
        }

        if let array = value as? [Any] {
            for element in array {
                if let match = findTicketCompletedPayload(in: element) {
                    return match
                }
            }
        }

        return nil
    }

    private func conversationPrompt(
        ticket: Ticket,
        mode: TicketConversationMode,
        summary: String,
        messages: [TicketConversationMessageRecord]
    ) -> String {
        let modeInstruction: String = switch mode {
        case .plan:
            """
            You are in PLAN mode.
            Focus on planning, design, and questions only.
            Do not perform implementation actions.
            """
        case .implement:
            """
            You are in IMPLEMENT mode.
            Execute implementation actions and provide concrete progress.
            """
        }

        let summaryBlock = summary.isEmpty ? "(none)" : summary
        let messageLines = messages
            .map { message in
                let flattened = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = flattened.isEmpty ? "(empty)" : flattened
                return "\(message.role.rawValue): \(content)"
            }
            .joined(separator: "\n")

        return """
        \(modeInstruction)

        Ticket ID: \(ticket.displayID)
        Ticket Title: \(ticket.title)
        Ticket Description: \(ticket.ticketDescription.isEmpty ? "(none)" : ticket.ticketDescription)

        Rolling Summary:
        \(summaryBlock)

        Recent Conversation:
        \(messageLines.isEmpty ? "(none)" : messageLines)
        """
    }

    private func synthesizedImplementationHandoff(
        summary: String,
        messages: [TicketConversationMessageRecord]
    ) -> String {
        let summaryBlock = summary.isEmpty ? "(none)" : summary
        let recentContext = messages.suffix(6).map { message in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(message.role.rawValue): \(content.isEmpty ? "(empty)" : content)"
        }.joined(separator: "\n")

        return """
        Start implementation now using the agreed plan.
        Preserve prior decisions and constraints.

        Rolling Summary:
        \(summaryBlock)

        Latest Context:
        \(recentContext.isEmpty ? "(none)" : recentContext)
        """
    }

    private func setTicketSending(_ isSending: Bool, for ticketID: UUID) {
        var updated = ticketIsSending
        if isSending {
            updated[ticketID] = true
        } else {
            updated.removeValue(forKey: ticketID)
            ticketSendingModes.removeValue(forKey: ticketID)
        }
        ticketIsSending = updated
    }

    private func resolvedConversationModeForTicketStart(ticketID: UUID) -> TicketConversationMode {
        if let mode = ticketConversationModes[ticketID] {
            return mode
        }
        if let mode = try? conversationStore.mode(ticketID: ticketID) {
            ticketConversationModes[ticketID] = mode
            return mode
        }
        return .plan
    }

    private func markCurrentLoopTicketAsInProgress(projectID: UUID, fallbackTickets: [LoopTicketItem]) async {
        let currentTicketID: UUID? = switch await loopManager.state(projectID: projectID) {
        case let .running(progress), let .paused(_, progress), let .failed(_, progress), let .cancelling(progress):
            progress.currentTicketID
        case .idle, .preparingQueue, .completed:
            nil
        }

        guard let ticketID = currentTicketID ?? fallbackTickets.first?.id else {
            return
        }
        setTicketStatus(ticketID: ticketID, status: .inProgress)
    }

    private func setTicketStatus(ticketID: UUID, status: TicketQuickStatus) {
        guard let modelContext else {
            let message = "Missing model context while setting ticket status to \(status.rawValue) for \(ticketID.uuidString)."
            Self.statusLogger.error("\(message, privacy: .public)")
            #if DEBUG
                debugAssertionHandler(message, #fileID, #line)
            #endif
            return
        }

        do {
            let descriptor = FetchDescriptor<Ticket>(
                predicate: #Predicate<Ticket> { ticket in
                    ticket.id == ticketID
                }
            )
            guard let ticket = try modelContext.fetch(descriptor).first else {
                return
            }
            guard ticket.quickStatus != status else {
                return
            }

            ticket.quickStatus = status
            ticket.updatedAt = .now
            try modelContext.save()
        } catch {
            NSLog("Failed to update ticket status for loop task start: %@", error.localizedDescription)
        }
    }

    private func resolveProjectWorkingDirectory(_ project: Project) throws -> String {
        guard let workingDirectory = project.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), workingDirectory.isEmpty == false else {
            throw CodexManager.ManagerError.missingWorkingDirectory
        }
        return workingDirectory
    }

    private func loopTicketItems(from tickets: [Ticket], projectID: UUID) -> [LoopTicketItem] {
        tickets
            .filter { ticket in
                ticket.projectID == projectID &&
                    ticket.archivedAt == nil &&
                    ticket.closedAt == nil &&
                    ticket.quickStatus.isLoopTerminalGroup == false
            }
            .sorted(by: { lhs, rhs in
                if lhs.orderKey == rhs.orderKey {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.orderKey < rhs.orderKey
            })
            .map { ticket in
                LoopTicketItem(
                    id: ticket.id,
                    displayID: ticket.displayID,
                    title: ticket.title,
                    description: ticket.ticketDescription
                )
            }
    }
}

private extension TicketQuickStatus {
    var isLoopTerminalGroup: Bool {
        self == .done || self == .skipped || self == .duplicate
    }
}
