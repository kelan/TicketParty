import Darwin
import Foundation
import Observation
import TicketPartyDataStore

enum CodexProjectStatus: Sendable, Equatable {
    case stopped
    case starting
    case running
    case error(String)

    var title: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case let .error(message):
            return "Error: \(message)"
        }
    }
}

actor CodexManager {
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
                return "Project working directory is required before sending to Codex."
            case let .invalidWorkingDirectory(path):
                return "Project working directory is invalid: \(path)"
            case let .supervisorUnavailable(message):
                return "Could not reach codex-supervisor: \(message)"
            case let .invalidResponse(message):
                return "Supervisor returned invalid data: \(message)"
            case let .requestFailed(message):
                return "Supervisor request failed: \(message)"
            }
        }
    }

    private struct SendTicketRequest: Encodable {
        let type = "sendTicket"
        let projectID: String
        let ticketID: String
        let requestID: String
        let workingDirectory: String
        let prompt: String
    }

    private struct SubscribeRequest: Encodable {
        let type = "subscribe"
    }

    private struct WorkerStatusRequest: Encodable {
        let type = "workerStatus"
        let projectID: String?
    }

    private struct StopWorkerRequest: Encodable {
        let type = "stopWorker"
        let projectID: String
    }

    private struct WorkerSnapshot: Sendable {
        let projectID: UUID
        let isRunning: Bool
        let activeRequestID: UUID?
        let activeTicketID: UUID?
    }

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let fileManager: FileManager
    private let supervisorSocketPath: String

    private var statuses: [UUID: CodexProjectStatus] = [:]
    private var requestToTicket: [UUID: UUID] = [:]
    private var requestToProject: [UUID: UUID] = [:]
    private var userStoppedProjects: Set<UUID> = []
    private var subscriptionTask: Task<Void, Never>?

    init(
        supervisorSocketPath: String = "$HOME/Library/Application Support/TicketParty/runtime/supervisor.sock",
        fileManager: FileManager = .default
    ) {
        var streamContinuation: AsyncStream<Event>.Continuation?
        events = AsyncStream<Event> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation!

        self.fileManager = fileManager
        self.supervisorSocketPath = Self.expandPath(supervisorSocketPath)

        subscriptionTask = nil
        Task { [weak self] in
            await self?.startSubscriptionTaskIfNeeded()
        }
    }

    deinit {
        subscriptionTask?.cancel()
        continuation.finish()
    }

    func status(for projectID: UUID) -> CodexProjectStatus {
        statuses[projectID] ?? .stopped
    }

    func sendTicket(
        projectID: UUID,
        workingDirectory: String?,
        ticketID: UUID,
        title: String,
        description: String
    ) async throws {
        let resolvedWorkingDirectory = try resolveWorkingDirectory(workingDirectory)
        startSubscriptionTaskIfNeeded()

        let requestID = UUID()
        let request = SendTicketRequest(
            projectID: projectID.uuidString,
            ticketID: ticketID.uuidString,
            requestID: requestID.uuidString,
            workingDirectory: resolvedWorkingDirectory,
            prompt: "\(title)\n\(description)"
        )

        let payload = try Self.encodeLine(request)

        let maxAttempts = 4
        var attempt = 0
        while true {
            attempt += 1

            let responseObject: [String: Any]
            do {
                responseObject = try Self.sendRequest(
                    payload: payload,
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
                if Self.isBusyInFlightMessage(message) {
                    if try reattachToInFlightRequest(projectID: projectID, requestedTicketID: ticketID) {
                        return
                    }
                    if attempt < maxAttempts {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }
                throw ManagerError.requestFailed(message)
            }

            guard type == "sendTicket.ok" else {
                throw ManagerError.invalidResponse("Unexpected sendTicket response type '\(type)'.")
            }

            break
        }

        requestToTicket[requestID] = ticketID
        requestToProject[requestID] = projectID
        // sendTicket.ok confirms supervisor accepted the request; treat project as active.
        setStatus(.running, for: projectID)
    }

    func stopWorker(projectID: UUID) throws {
        startSubscriptionTaskIfNeeded()
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

    private func startSubscriptionTaskIfNeeded() {
        if let subscriptionTask, subscriptionTask.isCancelled == false {
            return
        }

        let socketPath = supervisorSocketPath
        subscriptionTask = Task.detached { [weak self, socketPath] in
            await Self.runSubscriptionLoop(socketPath: socketPath) { [weak self] in
                self
            }
        }
    }

    private func consumeSupervisorLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        guard let type = payload["type"] as? String else { return }

        switch type {
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
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            let line = payload["text"] as? String ?? ""
            continuation.yield(.ticketOutput(ticketID: ticketID, line: line))

        case "ticket.error":
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            let message = payload["message"] as? String ?? "Unknown ticket error"
            continuation.yield(.ticketError(ticketID: ticketID, message: message))

        case "ticket.completed":
            guard let ticketID = resolveTicketID(payload: payload) else { return }
            let success = payload["success"] as? Bool ?? false
            let summary = payload["summary"] as? String
            continuation.yield(.ticketCompleted(ticketID: ticketID, success: success, summary: summary))
            clearRequestMappings(payload: payload)

        default:
            break
        }
    }

    private func handleSubscriptionDisconnected() {
        // Keep current status unchanged; reconnect loop will restore streaming on success.
    }

    private func refreshWorkerStateSnapshot() {
        guard let snapshots = try? fetchWorkerSnapshots(projectID: nil) else { return }
        applyWorkerSnapshots(snapshots)
    }

    private func applyWorkerSnapshots(_ snapshots: [WorkerSnapshot]) {
        for snapshot in snapshots {
            if snapshot.isRunning {
                setStatus(.running, for: snapshot.projectID)
            }

            if
                let activeRequestID = snapshot.activeRequestID,
                let activeTicketID = snapshot.activeTicketID
            {
                requestToTicket[activeRequestID] = activeTicketID
                requestToProject[activeRequestID] = snapshot.projectID
            }

            if let activeTicketID = snapshot.activeTicketID {
                continuation.yield(.ticketStarted(ticketID: activeTicketID))
            }
        }
    }

    private func reattachToInFlightRequest(projectID: UUID, requestedTicketID: UUID) throws -> Bool {
        guard let snapshot = try fetchWorkerSnapshots(projectID: projectID).first else {
            return false
        }

        applyWorkerSnapshots([snapshot])
        return snapshot.activeTicketID == requestedTicketID
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

        return workerArray.compactMap { worker in
            guard
                let projectIDRaw = worker["projectID"] as? String,
                let resolvedProjectID = UUID(uuidString: projectIDRaw)
            else {
                return nil
            }

            let isRunning = worker["isRunning"] as? Bool ?? false
            let activeRequestID = parseUUID(worker["activeRequestID"] as? String)
            let activeTicketID = parseUUID(worker["activeTicketID"] as? String)
            return WorkerSnapshot(
                projectID: resolvedProjectID,
                isRunning: isRunning,
                activeRequestID: activeRequestID,
                activeTicketID: activeTicketID
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
        requestToTicket.removeValue(forKey: requestID)
        requestToProject.removeValue(forKey: requestID)
    }

    private func setStatus(_ status: CodexProjectStatus, for projectID: UUID) {
        statuses[projectID] = status
        continuation.yield(.statusChanged(projectID: projectID, status: status))
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

    private nonisolated static func runSubscriptionLoop(
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
                await owner()?.handleSubscriptionDisconnected()
                try? await Task.sleep(nanoseconds: reconnectDelay)
                reconnectDelay = min(reconnectDelay * 2, 10_000_000_000)
                continue
            }

            defer { Darwin.close(fd) }

            do {
                let subscribePayload = try encodeLine(SubscribeRequest())
                guard writeAll(subscribePayload, to: fd) else {
                    throw ManagerError.supervisorUnavailable("Failed to write subscribe request.")
                }

                guard let responseLine = readLine(from: fd), let responseData = responseLine.data(using: .utf8) else {
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
                await owner()?.refreshWorkerStateSnapshot()

                while Task.isCancelled == false {
                    guard let line = readLine(from: fd) else {
                        break
                    }
                    guard let currentOwner = owner() else { return }
                    await currentOwner.consumeSupervisorLine(line)
                }
            } catch {
                await owner()?.handleSubscriptionDisconnected()
                try? await Task.sleep(nanoseconds: reconnectDelay)
                reconnectDelay = min(reconnectDelay * 2, 10_000_000_000)
                continue
            }

            await owner()?.handleSubscriptionDisconnected()
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

        guard let responseLine = readLine(from: fd), let responseData = responseLine.data(using: .utf8) else {
            throw ManagerError.supervisorUnavailable("Failed to read response.")
        }

        guard let responseObject = try (JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else {
            throw ManagerError.invalidResponse("Response was not a JSON object.")
        }

        return responseObject
    }

    private nonisolated static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
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

    private nonisolated static func readLine(from fd: Int32, maxBytes: Int = 65536) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

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

    private nonisolated static func isBusyInFlightMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("already has in-flight request")
    }
}

struct CodexTicketOutputSnapshot {
    let text: String
    let isTruncated: Bool
}

@MainActor
@Observable
final class CodexViewModel {
    private let manager: CodexManager
    private let supervisorHealthChecker: CodexSupervisorHealthChecker
    private let transcriptStore: TicketTranscriptStore
    private let minSpinnerDuration: Duration = .seconds(1)
    private var eventTask: Task<Void, Never>?
    private var supervisorHealthTask: Task<Void, Never>?

    var projectStatuses: [UUID: CodexProjectStatus] = [:]
    var ticketOutput: [UUID: String] = [:]
    var ticketErrors: [UUID: String] = [:]
    var ticketIsSending: [UUID: Bool] = [:]
    var activeRunByTicketID: [UUID: UUID] = [:]
    var supervisorHealth: CodexSupervisorHealthStatus = .notRunning

    init(
        manager: CodexManager = CodexManager(),
        supervisorHealthChecker: CodexSupervisorHealthChecker = CodexSupervisorHealthChecker(),
        transcriptStore: TicketTranscriptStore = TicketTranscriptStore()
    ) {
        self.manager = manager
        self.supervisorHealthChecker = supervisorHealthChecker
        self.transcriptStore = transcriptStore

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

        supervisorHealthTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshSupervisorHealth()
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(5))
                await self.refreshSupervisorHealth()
            }
        }
    }

    func send(ticket: Ticket, project: Project) async {
        let projectID = project.id
        let workingDirectory = project.workingDirectory
        let ticketID = ticket.id
        let title = ticket.title
        let description = ticket.ticketDescription
        let clock = ContinuousClock()
        let start = clock.now
        let runID: UUID

        guard ticketIsSending[ticketID] != true else {
            return
        }

        do {
            runID = try transcriptStore.startRun(projectID: projectID, ticketID: ticketID, requestID: nil)
            activeRunByTicketID[ticketID] = runID
            ticketOutput[ticketID] = ""
        } catch {
            ticketErrors[ticketID] = "Failed to start transcript run: \(error.localizedDescription)"
            return
        }

        ticketErrors[ticketID] = nil
        setTicketSending(true, for: ticketID)

        await Task.yield()

        do {
            try await manager.sendTicket(
                projectID: projectID,
                workingDirectory: workingDirectory,
                ticketID: ticketID,
                title: title,
                description: description
            )
        } catch {
            ticketErrors[ticketID] = error.localizedDescription
            do {
                try transcriptStore.completeRun(runID: runID, success: false, summary: error.localizedDescription)
            } catch {
                NSLog("Failed to finalize transcript for send error: %@", error.localizedDescription)
            }
            activeRunByTicketID.removeValue(forKey: ticketID)

            let elapsed = start.duration(to: clock.now)
            if elapsed < minSpinnerDuration {
                try? await Task.sleep(for: minSpinnerDuration - elapsed)
            }
            setTicketSending(false, for: ticketID)
        }
    }

    func stop(ticket: Ticket, project: Project) async {
        let ticketID = ticket.id

        do {
            try await manager.stopWorker(projectID: project.id)
            if let runID = activeRunByTicketID.removeValue(forKey: ticketID) {
                try? transcriptStore.completeRun(runID: runID, success: false, summary: "Cancelled by user.")
            }
            setTicketSending(false, for: ticketID)
        } catch {
            ticketErrors[ticketID] = error.localizedDescription
        }
    }

    func status(for projectID: UUID) -> CodexProjectStatus {
        projectStatuses[projectID] ?? .stopped
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

        case let .ticketCompleted(ticketID, success, summary):
            applyTicketCompletion(ticketID: ticketID, success: success, summary: summary)
        }
    }

    private func applyTicketCompletion(ticketID: UUID, success: Bool, summary: String?) {
        if let runID = activeRunByTicketID.removeValue(forKey: ticketID) {
            do {
                try transcriptStore.completeRun(runID: runID, success: success, summary: summary)
            } catch {
                NSLog("Failed to complete transcript run: %@", error.localizedDescription)
            }
        }

        if success {
            ticketErrors[ticketID] = nil
        } else if let summary, summary.isEmpty == false {
            ticketErrors[ticketID] = summary
        }
        setTicketSending(false, for: ticketID)
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

    private func setTicketSending(_ isSending: Bool, for ticketID: UUID) {
        var updated = ticketIsSending
        if isSending {
            updated[ticketID] = true
        } else {
            updated.removeValue(forKey: ticketID)
        }
        ticketIsSending = updated
    }
}
