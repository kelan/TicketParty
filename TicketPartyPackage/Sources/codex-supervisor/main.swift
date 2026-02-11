import Darwin
import Dispatch
import Foundation

private struct SupervisorConfiguration {
    let runtimeDirectory: String
    let recordPath: String
    let socketPath: String
    let protocolVersion: Int
    let sidecarScriptPath: String
    let nodeBinaryPath: String?

    static func make(arguments: [String]) throws -> SupervisorConfiguration {
        let defaultRuntime = "~/Library/Application Support/TicketParty/runtime"
        let defaultRecord = "\(defaultRuntime)/supervisor.json"
        let defaultSocket = "\(defaultRuntime)/supervisor.sock"
        let defaultSidecarScript = "~/dev/codex-sidecar/sidecar.mjs"

        var runtimeDirectory = defaultRuntime
        var recordPath = defaultRecord
        var socketPath = defaultSocket
        var protocolVersion = 2
        var sidecarScriptPath = defaultSidecarScript
        var nodeBinaryPath: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--runtime-dir":
                index += 1
                runtimeDirectory = try value(for: argument, in: arguments, at: index)
            case "--record-path":
                index += 1
                recordPath = try value(for: argument, in: arguments, at: index)
            case "--socket-path":
                index += 1
                socketPath = try value(for: argument, in: arguments, at: index)
            case "--protocol-version":
                index += 1
                let rawValue = try value(for: argument, in: arguments, at: index)
                guard let parsed = Int(rawValue), parsed > 0 else {
                    throw SupervisorError.invalidArgument(
                        "Expected a positive integer for --protocol-version, got '\(rawValue)'."
                    )
                }
                protocolVersion = parsed
            case "--sidecar-script":
                index += 1
                sidecarScriptPath = try value(for: argument, in: arguments, at: index)
            case "--node-binary":
                index += 1
                nodeBinaryPath = try value(for: argument, in: arguments, at: index)
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw SupervisorError.invalidArgument("Unknown argument: \(argument)")
            }
            index += 1
        }

        return SupervisorConfiguration(
            runtimeDirectory: normalizePath(runtimeDirectory),
            recordPath: normalizePath(recordPath),
            socketPath: normalizePath(socketPath),
            protocolVersion: protocolVersion,
            sidecarScriptPath: normalizePath(sidecarScriptPath),
            nodeBinaryPath: nodeBinaryPath.map(normalizePath)
        )
    }

    private static func value(for flag: String, in arguments: [String], at index: Int) throws -> String {
        guard index < arguments.count else {
            throw SupervisorError.invalidArgument("Missing value for \(flag)")
        }
        return arguments[index]
    }

    private static func normalizePath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

private struct SupervisorRuntimeRecord: Codable {
    let pid: Int32
    let startedAtEpochMS: Int64
    let protocolVersion: Int
    let binaryPath: String
    let binaryHash: String?
    let controlEndpoint: String
    let instanceToken: String
}

private struct ControlRequest: Decodable {
    let type: String
    let minProtocolVersion: Int?
    let expectedInstanceToken: String?
    let projectID: String?
    let ticketID: String?
    let requestID: String?
    let taskID: String?
    let kind: String?
    let idempotencyKey: String?
    let payload: [String: String]?
    let fromEventID: Int64?
    let upToEventID: Int64?
    let workingDirectory: String?
    let prompt: String?
}

private struct HelloResponse: Encodable {
    let type = "hello.ok"
    let pid: Int32
    let protocolVersion: Int
    let instanceToken: String
    let serverTimeEpochMS: Int64
}

private struct AckResponse: Encodable {
    let type: String
    let message: String?
}

private struct SubmitTaskResponse: Encodable {
    let type = "submitTask.ok"
    let taskID: String
    let deduplicated: Bool
}

private struct ErrorResponse: Encodable {
    let type = "error"
    let message: String
}

private struct WorkerStatusEntry: Encodable {
    let projectID: String
    let isRunning: Bool
    let activeRequestID: String?
    let activeTicketID: String?
}

private struct WorkerStatusResponse: Encodable {
    let type = "workerStatus.ok"
    let workers: [WorkerStatusEntry]
}

private struct TaskStatusEntry: Codable {
    let projectID: String
    let taskID: String
    let ticketID: String?
    let kind: String
    var state: String
    let idempotencyKey: String?
    let startedAtEpochMS: Int64
    var completedAtEpochMS: Int64?
    var success: Bool?
    var summary: String?
}

private struct TaskStatusResponse: Encodable {
    let type = "taskStatus.ok"
    let tasks: [TaskStatusEntry]
}

private struct ActiveTaskEntry: Encodable {
    let projectID: String
    let taskID: String
    let ticketID: String?
    let kind: String
}

private struct ActiveTasksResponse: Encodable {
    let type = "listActiveTasks.ok"
    let tasks: [ActiveTaskEntry]
}

private struct SupervisorEvent: Codable {
    let type: String
    let eventID: Int64?
    let timestampEpochMS: Int64?
    let projectID: String?
    let ticketID: String?
    let requestID: String?
    let pid: Int32?
    let text: String?
    let message: String?
    let success: Bool?
    let summary: String?
    let threadID: String?

    init(
        type: String,
        eventID: Int64? = nil,
        timestampEpochMS: Int64? = nil,
        projectID: String?,
        ticketID: String?,
        requestID: String?,
        pid: Int32?,
        text: String?,
        message: String?,
        success: Bool?,
        summary: String?,
        threadID: String?
    ) {
        self.type = type
        self.eventID = eventID
        self.timestampEpochMS = timestampEpochMS
        self.projectID = projectID
        self.ticketID = ticketID
        self.requestID = requestID
        self.pid = pid
        self.text = text
        self.message = message
        self.success = success
        self.summary = summary
        self.threadID = threadID
    }
}

private struct SidecarCommand: Encodable {
    let threadId: String
    let requestId: String
    let prompt: String
}

private struct ActiveRequest {
    let requestID: UUID
    let projectID: UUID
    let ticketID: UUID
    let kind: String
    let idempotencyKey: String?
}

private enum StreamSource {
    case stdout
    case stderr
}

private struct ProjectLogMeta: Codable {
    var nextEventID: Int64
    var lastAckedEventID: Int64
}

private struct LocalCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private enum SupervisorError: LocalizedError {
    case invalidArgument(String)
    case failedToCreateDirectory(String)
    case failedToWriteRuntimeRecord(String)
    case failedToDeleteRuntimeRecord(String)
    case failedToStartControlServer(String)
    case invalidSocketPath(String)
    case invalidRequest(String)
    case invalidWorkingDirectory(String)
    case missingNodeBinary
    case missingSidecarScript(String)
    case sidecarLaunchFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message):
            return message
        case let .failedToCreateDirectory(message):
            return "Failed to create runtime directory: \(message)"
        case let .failedToWriteRuntimeRecord(message):
            return "Failed to write runtime record: \(message)"
        case let .failedToDeleteRuntimeRecord(message):
            return "Failed to delete runtime record: \(message)"
        case let .failedToStartControlServer(message):
            return "Failed to start control server: \(message)"
        case let .invalidSocketPath(path):
            return "Socket path is too long for unix domain socket: \(path)"
        case let .invalidRequest(message):
            return message
        case let .invalidWorkingDirectory(path):
            return "Project working directory is invalid: \(path)"
        case .missingNodeBinary:
            return "Node.js executable not found. Install Node or provide --node-binary."
        case let .missingSidecarScript(path):
            return "Codex sidecar script not found: \(path)"
        case let .sidecarLaunchFailed(message):
            return "Failed to launch sidecar: \(message)"
        case let .sendFailed(message):
            return "Failed to send ticket to sidecar: \(message)"
        }
    }
}

private final class WorkerSession {
    let projectID: UUID
    let process: Process
    let stdin: FileHandle
    let stdout: FileHandle
    let stderr: FileHandle
    let pid: Int32
    let workingDirectory: String

    var stdoutBuffer: Data = .init()
    var stderrBuffer: Data = .init()
    var activeRequestID: UUID?

    init(
        projectID: UUID,
        process: Process,
        stdin: FileHandle,
        stdout: FileHandle,
        stderr: FileHandle,
        pid: Int32,
        workingDirectory: String
    ) {
        self.projectID = projectID
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.pid = pid
        self.workingDirectory = workingDirectory
    }
}

private final class ControlServer: @unchecked Sendable {
    private struct Subscriber {
        let fd: Int32
        let projectID: UUID?
    }

    private static let maxEventLogBytes = 10 * 1024 * 1024
    private static let maxEventAgeMS: Int64 = 7 * 24 * 60 * 60 * 1000

    private let runtimeDirectory: String
    private let socketPath: String
    private let protocolVersion: Int
    private let instanceToken: String
    private let sidecarScriptPath: String
    private let nodeBinaryPath: String?
    private let fileManager: FileManager

    private let queue = DispatchQueue(label: "io.kelan.ticketparty.codex-supervisor.control")
    private var listeningFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var subscribers: [Int32: Subscriber] = [:]
    private var workers: [UUID: WorkerSession] = [:]
    private var activeRequests: [UUID: ActiveRequest] = [:]
    private var taskRecords: [UUID: [UUID: TaskStatusEntry]] = [:]
    private var idempotencyIndex: [UUID: [String: UUID]] = [:]
    private var projectMeta: [UUID: ProjectLogMeta] = [:]
    private var runningTaskProcesses: [UUID: Process] = [:]

    init(
        runtimeDirectory: String,
        socketPath: String,
        protocolVersion: Int,
        instanceToken: String,
        sidecarScriptPath: String,
        nodeBinaryPath: String?,
        fileManager: FileManager = .default
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.socketPath = socketPath
        self.protocolVersion = protocolVersion
        self.instanceToken = instanceToken
        self.sidecarScriptPath = sidecarScriptPath
        self.nodeBinaryPath = nodeBinaryPath
        self.fileManager = fileManager
    }

    func start() throws {
        try preparePersistenceDirectories()
        try loadPersistedProjectState()

        let socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try fileManager.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SupervisorError.failedToStartControlServer(String(cString: strerror(errno)))
        }

        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
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
            throw SupervisorError.invalidSocketPath(socketPath)
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
            throw SupervisorError.failedToStartControlServer("bind failed: \(message)")
        }

        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw SupervisorError.failedToStartControlServer("listen failed: \(message)")
        }

        _ = chmod(socketPath, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listeningFD >= 0 {
                Darwin.close(self.listeningFD)
                self.listeningFD = -1
            }
        }

        listeningFD = fd
        readSource = source
        source.resume()
    }

    func stop() {
        queue.sync {
            for (subscriberFD, _) in subscribers {
                Darwin.close(subscriberFD)
            }
            subscribers.removeAll()

            for process in runningTaskProcesses.values where process.isRunning {
                process.terminate()
            }
            runningTaskProcesses.removeAll()

            let projectIDs = Array(workers.keys)
            for projectID in projectIDs {
                stopWorker(projectID: projectID, emitWorkerExit: false)
            }

            readSource?.cancel()
            readSource = nil

            if listeningFD >= 0 {
                Darwin.close(listeningFD)
                listeningFD = -1
            }

            unlink(socketPath)
        }
    }

    private func acceptPendingConnections() {
        while true {
            let clientFD = Darwin.accept(listeningFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                if errno == EINTR {
                    continue
                }
                return
            }

            handleClientConnection(fd: clientFD)
        }
    }

    private func handleClientConnection(fd: Int32) {
        setNoSigPipe(fd: fd)
        setTimeout(fd: fd, option: SO_RCVTIMEO, seconds: 5)
        setTimeout(fd: fd, option: SO_SNDTIMEO, seconds: 5)

        guard let requestLine = readLine(from: fd) else {
            _ = sendError("Failed to read request.", to: fd)
            Darwin.close(fd)
            return
        }

        guard let requestData = requestLine.data(using: .utf8) else {
            _ = sendError("Request was not UTF-8.", to: fd)
            Darwin.close(fd)
            return
        }

        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: requestData)
        } catch {
            _ = sendError("Invalid request JSON: \(error.localizedDescription)", to: fd)
            Darwin.close(fd)
            return
        }

        let keepConnectionOpen = handleRequest(request, fd: fd)
        if keepConnectionOpen == false {
            Darwin.close(fd)
        }
    }

    private func handleRequest(_ request: ControlRequest, fd: Int32) -> Bool {
        do {
            switch request.type {
            case "hello":
                try handleHello(request: request, fd: fd)
                return false
            case "subscribe":
                try handleSubscribe(request: request, fd: fd)
                return true
            case "submitTask":
                try handleSubmitTask(request: request, fd: fd)
                return false
            case "sendTicket":
                try handleSendTicket(request: request, fd: fd)
                return false
            case "ack":
                try handleAck(request: request, fd: fd)
                return false
            case "taskStatus":
                try handleTaskStatus(request: request, fd: fd)
                return false
            case "listActiveTasks":
                try handleListActiveTasks(fd: fd)
                return false
            case "cancelTask":
                try handleCancelTask(request: request, fd: fd)
                return false
            case "workerStatus":
                try handleWorkerStatus(request: request, fd: fd)
                return false
            case "stopWorker":
                try handleStopWorker(request: request, fd: fd)
                return false
            case "shutdownSupervisor":
                _ = sendJSON(AckResponse(type: "shutdownSupervisor.ok", message: nil), to: fd)
                DispatchQueue.global().async {
                    Darwin.raise(SIGTERM)
                }
                return false
            default:
                _ = sendError("Unknown request type '\(request.type)'.", to: fd)
                return false
            }
        } catch {
            _ = sendError(error.localizedDescription, to: fd)
            return false
        }
    }

    private func handleHello(request: ControlRequest, fd: Int32) throws {
        let minimumProtocol = request.minProtocolVersion ?? 1
        if protocolVersion < minimumProtocol {
            throw SupervisorError.invalidRequest(
                "Protocol version \(protocolVersion) is below required minimum \(minimumProtocol)."
            )
        }

        if let expectedToken = request.expectedInstanceToken, expectedToken != instanceToken {
            throw SupervisorError.invalidRequest("Instance token mismatch.")
        }

        let response = HelloResponse(
            pid: getpid(),
            protocolVersion: protocolVersion,
            instanceToken: instanceToken,
            serverTimeEpochMS: Int64(Date().timeIntervalSince1970 * 1000)
        )
        _ = sendJSON(response, to: fd)
    }

    private func handleSubscribe(request: ControlRequest, fd: Int32) throws {
        let filteredProjectID: UUID?
        if let projectIDRaw = request.projectID {
            guard let parsed = UUID(uuidString: projectIDRaw) else {
                throw SupervisorError.invalidRequest("subscribe projectID must be a valid UUID.")
            }
            filteredProjectID = parsed
        } else {
            filteredProjectID = nil
        }

        if request.fromEventID != nil, filteredProjectID == nil {
            throw SupervisorError.invalidRequest("subscribe fromEventID requires projectID.")
        }

        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        guard sendJSON(AckResponse(type: "subscribe.ok", message: nil), to: fd) else {
            throw SupervisorError.sendFailed("Failed to confirm subscription.")
        }

        if let filteredProjectID, let fromEventID = request.fromEventID {
            try replayEvents(projectID: filteredProjectID, fromEventID: fromEventID, to: fd)
        }

        subscribers[fd] = Subscriber(fd: fd, projectID: filteredProjectID)
    }

    private func handleSubmitTask(request: ControlRequest, fd: Int32) throws {
        let taskIDRaw = request.taskID ?? request.requestID
        guard
            let projectIDRaw = request.projectID,
            let taskIDRaw,
            let kind = request.kind
        else {
            throw SupervisorError.invalidRequest("submitTask requires projectID, taskID, and kind.")
        }

        guard
            let projectID = UUID(uuidString: projectIDRaw),
            let taskID = UUID(uuidString: taskIDRaw)
        else {
            throw SupervisorError.invalidRequest("submitTask IDs must be valid UUID strings.")
        }

        if let existingTaskID = findDeduplicatedTask(projectID: projectID, idempotencyKey: request.idempotencyKey) {
            _ = sendJSON(
                SubmitTaskResponse(taskID: existingTaskID.uuidString, deduplicated: true),
                to: fd
            )
            return
        }

        switch kind {
        case "codex.ticket":
            try startCodexTicketTask(
                request: request,
                projectID: projectID,
                taskID: taskID,
                kind: "codex.ticket",
                fd: fd
            )

        case "cleanup.requestRefactor", "cleanup.applyRefactor":
            try startCodexTicketTask(
                request: request,
                projectID: projectID,
                taskID: taskID,
                kind: kind,
                fd: fd
            )

        case "cleanup.commitImplementation",
             "cleanup.commitRefactor",
             "cleanup.verifyCleanWorktree",
             "cleanup.runUnitTests":
            try startLocalCleanupTask(
                request: request,
                projectID: projectID,
                taskID: taskID,
                kind: kind,
                fd: fd
            )

        default:
            let summary = "Unsupported task kind '\(kind)'."
            recordTaskAccepted(
                projectID: projectID,
                taskID: taskID,
                ticketID: nil,
                kind: kind,
                idempotencyKey: request.idempotencyKey
            )
            recordTaskFailure(projectID: projectID, taskID: taskID, summary: summary)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            emitTaskFailed(
                projectID: projectID,
                ticketID: nil,
                requestID: taskID,
                message: summary,
                timestampEpochMS: now
            )
            throw SupervisorError.invalidRequest(summary)
        }
    }

    private func handleSendTicket(request: ControlRequest, fd: Int32) throws {
        guard let projectIDRaw = request.projectID, let taskIDRaw = request.requestID else {
            throw SupervisorError.invalidRequest("sendTicket requires projectID and requestID.")
        }
        guard
            let projectID = UUID(uuidString: projectIDRaw),
            let taskID = UUID(uuidString: taskIDRaw)
        else {
            throw SupervisorError.invalidRequest("sendTicket IDs must be valid UUID strings.")
        }

        try startCodexTicketTask(
            request: request,
            projectID: projectID,
            taskID: taskID,
            kind: "codex.ticket",
            fd: fd
        )
    }

    private func startCodexTicketTask(
        request: ControlRequest,
        projectID: UUID,
        taskID: UUID,
        kind: String,
        fd: Int32
    ) throws {
        guard
            let ticketIDRaw = request.ticketID,
            let prompt = request.prompt,
            let workingDirectory = request.workingDirectory
        else {
            throw SupervisorError.invalidRequest("codex.ticket requires ticketID, workingDirectory, and prompt.")
        }

        guard
            let ticketID = UUID(uuidString: ticketIDRaw)
        else {
            throw SupervisorError.invalidRequest("codex.ticket ticketID must be a valid UUID string.")
        }

        let resolvedWorkingDirectory = try resolveWorkingDirectory(workingDirectory)

        if let existing = firstInFlightRequest(projectID: projectID, excluding: taskID) {
            throw SupervisorError.invalidRequest(
                "Project \(projectID.uuidString) already has in-flight request \(existing.requestID.uuidString)."
            )
        }

        let session = try ensureWorker(projectID: projectID, workingDirectory: resolvedWorkingDirectory)

        if let existingRequestID = session.activeRequestID, existingRequestID != taskID {
            if activeRequests[existingRequestID] == nil {
                // Recover from stale local state if prior request mapping was already dropped.
                session.activeRequestID = nil
            } else {
                throw SupervisorError.invalidRequest(
                    "Project \(projectID.uuidString) already has in-flight request \(existingRequestID.uuidString)."
                )
            }
        }

        let payload = SidecarCommand(
            threadId: ticketID.uuidString,
            requestId: taskID.uuidString,
            prompt: prompt
        )
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)

        do {
            try session.stdin.write(contentsOf: data)
        } catch {
            throw SupervisorError.sendFailed(error.localizedDescription)
        }

        session.activeRequestID = taskID
        activeRequests[taskID] = ActiveRequest(
            requestID: taskID,
            projectID: projectID,
            ticketID: ticketID,
            kind: kind,
            idempotencyKey: request.idempotencyKey
        )
        recordTaskAccepted(
            projectID: projectID,
            taskID: taskID,
            ticketID: ticketID,
            kind: kind,
            idempotencyKey: request.idempotencyKey
        )
        emitTaskAccepted(projectID: projectID, ticketID: ticketID, requestID: taskID)

        if request.type == "sendTicket" {
            _ = sendJSON(AckResponse(type: "sendTicket.ok", message: nil), to: fd)
        } else {
            _ = sendJSON(SubmitTaskResponse(taskID: taskID.uuidString, deduplicated: false), to: fd)
        }
    }

    private func startLocalCleanupTask(
        request: ControlRequest,
        projectID: UUID,
        taskID: UUID,
        kind: String,
        fd: Int32
    ) throws {
        guard
            let ticketIDRaw = request.ticketID,
            let ticketID = UUID(uuidString: ticketIDRaw),
            let workingDirectory = request.workingDirectory
        else {
            throw SupervisorError.invalidRequest("\(kind) requires ticketID and workingDirectory.")
        }

        if let existing = firstInFlightRequest(projectID: projectID, excluding: taskID) {
            throw SupervisorError.invalidRequest(
                "Project \(projectID.uuidString) already has in-flight request \(existing.requestID.uuidString)."
            )
        }

        let resolvedWorkingDirectory = try resolveWorkingDirectory(workingDirectory)
        let activeRequest = ActiveRequest(
            requestID: taskID,
            projectID: projectID,
            ticketID: ticketID,
            kind: kind,
            idempotencyKey: request.idempotencyKey
        )

        activeRequests[taskID] = activeRequest
        recordTaskAccepted(
            projectID: projectID,
            taskID: taskID,
            ticketID: ticketID,
            kind: kind,
            idempotencyKey: request.idempotencyKey
        )
        emitTaskAccepted(projectID: projectID, ticketID: ticketID, requestID: taskID)
        _ = sendJSON(SubmitTaskResponse(taskID: taskID.uuidString, deduplicated: false), to: fd)

        let payload = request.payload ?? [:]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let server = self else { return }
            let outcome = server.runLocalCleanupTask(
                taskID: taskID,
                kind: kind,
                ticketID: ticketID,
                workingDirectory: resolvedWorkingDirectory,
                payload: payload
            )

            server.queue.async {
                guard let request = server.activeRequests[taskID] else { return }

                for line in outcome.lines where line.isEmpty == false {
                    server.broadcast(
                        SupervisorEvent(
                            type: "task.output",
                            projectID: request.projectID.uuidString,
                            ticketID: request.ticketID.uuidString,
                            requestID: request.requestID.uuidString,
                            pid: nil,
                            text: line,
                            message: nil,
                            success: nil,
                            summary: nil,
                            threadID: nil
                        )
                    )
                }

                if outcome.success {
                    server.recordTaskCompletion(
                        projectID: request.projectID,
                        taskID: request.requestID,
                        success: true,
                        summary: outcome.summary
                    )
                    server.emitTaskCompleted(
                        projectID: request.projectID,
                        ticketID: request.ticketID,
                        requestID: request.requestID,
                        summary: outcome.summary
                    )
                } else {
                    let summary = outcome.summary ?? "\(kind) failed."
                    server.recordTaskFailure(
                        projectID: request.projectID,
                        taskID: request.requestID,
                        summary: summary
                    )
                    server.emitTaskFailed(
                        projectID: request.projectID,
                        ticketID: request.ticketID,
                        requestID: request.requestID,
                        message: summary
                    )
                }

                server.clearRequest(request)
            }
        }
    }

    private func runLocalCleanupTask(
        taskID: UUID,
        kind: String,
        ticketID _: UUID,
        workingDirectory: String,
        payload: [String: String]
    ) -> (success: Bool, summary: String?, lines: [String]) {
        switch kind {
        case "cleanup.commitImplementation", "cleanup.commitRefactor":
            return runCommitTask(
                taskID: taskID,
                workingDirectory: workingDirectory,
                payload: payload
            )

        case "cleanup.verifyCleanWorktree":
            let status = runLocalCommand(
                taskID: taskID,
                executable: "/usr/bin/git",
                arguments: ["status", "--porcelain"],
                workingDirectory: workingDirectory
            )
            let dirtyLines = Self.splitOutput(status.stdout).filter { $0.isEmpty == false }
            if status.exitCode == 0, dirtyLines.isEmpty {
                return (true, "Worktree clean.", [])
            }
            if status.exitCode != 0 {
                let summary = status.stderr.isEmpty ? "Failed to check worktree status." : status.stderr
                return (false, summary, Self.splitOutput(status.stderr))
            }
            return (false, "Worktree is not clean.", dirtyLines)

        case "cleanup.runUnitTests":
            let command = payload["command"]
                ?? "xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' test -only-testing:TicketPartyTests"
            let result = runLocalCommand(
                taskID: taskID,
                executable: "/bin/zsh",
                arguments: ["-lc", command],
                workingDirectory: workingDirectory
            )
            let lines = Self.splitOutput(result.stdout + (result.stderr.isEmpty ? "" : "\n\(result.stderr)"))
            if result.exitCode == 0 {
                return (true, "Unit tests passed.", lines)
            }
            return (false, "Unit tests failed.", lines)

        default:
            return (false, "Unsupported cleanup task kind '\(kind)'.", [])
        }
    }

    private func runCommitTask(
        taskID: UUID,
        workingDirectory: String,
        payload: [String: String]
    ) -> (success: Bool, summary: String?, lines: [String]) {
        var lines: [String] = []

        let status = runLocalCommand(
            taskID: taskID,
            executable: "/usr/bin/git",
            arguments: ["status", "--porcelain"],
            workingDirectory: workingDirectory
        )
        lines.append(contentsOf: Self.splitOutput(status.stdout))
        if status.exitCode != 0 {
            lines.append(contentsOf: Self.splitOutput(status.stderr))
            return (false, "Failed to inspect git status before commit.", lines)
        }
        if status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (false, "No changes to commit.", lines)
        }

        let add = runLocalCommand(
            taskID: taskID,
            executable: "/usr/bin/git",
            arguments: ["add", "-A"],
            workingDirectory: workingDirectory
        )
        lines.append(contentsOf: Self.splitOutput(add.stdout))
        if add.exitCode != 0 {
            lines.append(contentsOf: Self.splitOutput(add.stderr))
            return (false, "Failed to stage changes for commit.", lines)
        }

        let normalizedTitle = payload["ticketTitle"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = normalizedTitle.isEmpty ? "Untitled Ticket" : normalizedTitle
        let description = Self.summaryDescription(payload["ticketDescription"] ?? "")
        let normalizedBase = payload["baseMessage"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseMessage = normalizedBase.isEmpty ? "Ticket update" : normalizedBase
        let includeAgentTrailer = (payload["includeAgentTrailer"] ?? "true").lowercased() != "false"

        var arguments: [String] = [
            "codex-commit",
            "-m", baseMessage,
            "-m", "Ticket: \(title)",
            "-m", "Description: \(description)",
        ]
        if includeAgentTrailer {
            arguments += ["-m", "Agent: Codex"]
        }

        let commit = runLocalCommand(
            taskID: taskID,
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: workingDirectory
        )
        lines.append(contentsOf: Self.splitOutput(commit.stdout))
        lines.append(contentsOf: Self.splitOutput(commit.stderr))

        if commit.exitCode == 0 {
            return (true, baseMessage, lines)
        }
        return (false, "Commit failed for '\(title)'.", lines)
    }

    private func runLocalCommand(
        taskID: UUID,
        executable: String,
        arguments: [String],
        workingDirectory: String
    ) -> LocalCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        queue.sync {
            runningTaskProcesses[taskID] = process
        }

        do {
            try process.run()
        } catch {
            _ = queue.sync {
                runningTaskProcesses.removeValue(forKey: taskID)
            }
            return LocalCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        queue.sync {
            if runningTaskProcesses[taskID] === process {
                runningTaskProcesses.removeValue(forKey: taskID)
            }
        }

        return LocalCommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func handleWorkerStatus(request: ControlRequest, fd: Int32) throws {
        var result: [WorkerStatusEntry] = []
        if let projectIDRaw = request.projectID {
            guard let projectID = UUID(uuidString: projectIDRaw) else {
                throw SupervisorError.invalidRequest("workerStatus projectID must be a UUID.")
            }
            if let session = workers[projectID] {
                let activeTicketID: String?
                if
                    let activeRequestID = session.activeRequestID,
                    let activeRequest = activeRequests[activeRequestID]
                {
                    activeTicketID = activeRequest.ticketID.uuidString
                } else {
                    activeTicketID = nil
                }
                result.append(
                    WorkerStatusEntry(
                        projectID: projectID.uuidString,
                        isRunning: session.process.isRunning,
                        activeRequestID: session.activeRequestID?.uuidString,
                        activeTicketID: activeTicketID
                    )
                )
            } else {
                result.append(
                    WorkerStatusEntry(
                        projectID: projectID.uuidString,
                        isRunning: false,
                        activeRequestID: nil,
                        activeTicketID: nil
                    )
                )
            }
        } else {
            result = workers.map { projectID, session in
                let activeTicketID: String?
                if
                    let activeRequestID = session.activeRequestID,
                    let activeRequest = activeRequests[activeRequestID]
                {
                    activeTicketID = activeRequest.ticketID.uuidString
                } else {
                    activeTicketID = nil
                }
                return WorkerStatusEntry(
                    projectID: projectID.uuidString,
                    isRunning: session.process.isRunning,
                    activeRequestID: session.activeRequestID?.uuidString,
                    activeTicketID: activeTicketID
                )
            }
        }

        _ = sendJSON(WorkerStatusResponse(workers: result.sorted { $0.projectID < $1.projectID }), to: fd)
    }

    private func handleAck(request: ControlRequest, fd: Int32) throws {
        guard
            let projectIDRaw = request.projectID,
            let projectID = UUID(uuidString: projectIDRaw),
            let upToEventID = request.upToEventID
        else {
            throw SupervisorError.invalidRequest("ack requires projectID UUID and upToEventID.")
        }

        var meta = projectMeta[projectID] ?? ProjectLogMeta(nextEventID: 1, lastAckedEventID: 0)
        meta.lastAckedEventID = max(meta.lastAckedEventID, upToEventID)
        projectMeta[projectID] = meta
        try persistProjectMeta(projectID: projectID)

        _ = sendJSON(AckResponse(type: "ack.ok", message: nil), to: fd)
    }

    private func handleTaskStatus(request: ControlRequest, fd: Int32) throws {
        if let taskIDRaw = request.taskID {
            guard let taskID = UUID(uuidString: taskIDRaw) else {
                throw SupervisorError.invalidRequest("taskStatus taskID must be a UUID.")
            }

            var tasks: [TaskStatusEntry] = []
            for projectTasks in taskRecords.values {
                if let task = projectTasks[taskID] {
                    tasks.append(task)
                }
            }
            _ = sendJSON(TaskStatusResponse(tasks: tasks), to: fd)
            return
        }

        if let projectIDRaw = request.projectID {
            guard let projectID = UUID(uuidString: projectIDRaw) else {
                throw SupervisorError.invalidRequest("taskStatus projectID must be a UUID.")
            }
            let tasks = Array((taskRecords[projectID] ?? [:]).values)
                .sorted { $0.startedAtEpochMS < $1.startedAtEpochMS }
            _ = sendJSON(TaskStatusResponse(tasks: tasks), to: fd)
            return
        }

        let tasks = taskRecords.values.flatMap(\.values)
            .sorted { $0.startedAtEpochMS < $1.startedAtEpochMS }
        _ = sendJSON(TaskStatusResponse(tasks: tasks), to: fd)
    }

    private func handleListActiveTasks(fd: Int32) throws {
        var active: [ActiveTaskEntry] = []
        for projectTasks in taskRecords.values {
            for task in projectTasks.values where task.state == "running" || task.state == "accepted" {
                active.append(
                    ActiveTaskEntry(
                        projectID: task.projectID,
                        taskID: task.taskID,
                        ticketID: task.ticketID,
                        kind: task.kind
                    )
                )
            }
        }
        active.sort {
            if $0.projectID == $1.projectID {
                return $0.taskID < $1.taskID
            }
            return $0.projectID < $1.projectID
        }
        _ = sendJSON(ActiveTasksResponse(tasks: active), to: fd)
    }

    private func handleCancelTask(request: ControlRequest, fd: Int32) throws {
        guard
            let projectIDRaw = request.projectID,
            let taskIDRaw = request.taskID,
            let projectID = UUID(uuidString: projectIDRaw),
            let taskID = UUID(uuidString: taskIDRaw)
        else {
            throw SupervisorError.invalidRequest("cancelTask requires projectID and taskID UUIDs.")
        }

        if let session = workers[projectID], session.activeRequestID == taskID {
            stopWorker(projectID: projectID, emitWorkerExit: true)
            recordTaskFailure(projectID: projectID, taskID: taskID, summary: "cancelled.force_terminated")
        }

        if let process = runningTaskProcesses[taskID], process.isRunning {
            process.terminate()
        }

        if let activeRequest = activeRequests[taskID] {
            recordTaskFailure(projectID: activeRequest.projectID, taskID: taskID, summary: "cancelled.force_terminated")
            emitTaskFailed(
                projectID: activeRequest.projectID,
                ticketID: activeRequest.ticketID,
                requestID: activeRequest.requestID,
                message: "cancelled.force_terminated"
            )
            clearRequest(activeRequest)
        }

        _ = sendJSON(AckResponse(type: "cancelTask.ok", message: nil), to: fd)
    }

    private func handleStopWorker(request: ControlRequest, fd: Int32) throws {
        guard let projectIDRaw = request.projectID, let projectID = UUID(uuidString: projectIDRaw) else {
            throw SupervisorError.invalidRequest("stopWorker requires a valid projectID UUID.")
        }

        stopWorker(projectID: projectID, emitWorkerExit: true)
        _ = sendJSON(AckResponse(type: "stopWorker.ok", message: nil), to: fd)
    }

    private func ensureWorker(projectID: UUID, workingDirectory: String) throws -> WorkerSession {
        if let existing = workers[projectID] {
            if existing.process.isRunning, existing.workingDirectory == workingDirectory {
                return existing
            }
            stopWorker(projectID: projectID, emitWorkerExit: false)
        }

        let sidecarScript = try resolveSidecarScriptPath()
        let nodeBinary = try resolveNodeExecutablePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodeBinary)
        process.arguments = [sidecarScript]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            guard let server = self else { return }
            let data = handle.availableData
            server.queue.async {
                server.consumeWorkerData(data: data, projectID: projectID, source: .stdout)
            }
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            guard let server = self else { return }
            let data = handle.availableData
            server.queue.async {
                server.consumeWorkerData(data: data, projectID: projectID, source: .stderr)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            guard let server = self else { return }
            server.queue.async {
                server.handleWorkerTermination(projectID: projectID, statusCode: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw SupervisorError.sidecarLaunchFailed(error.localizedDescription)
        }

        let session = WorkerSession(
            projectID: projectID,
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutHandle,
            stderr: stderrHandle,
            pid: process.processIdentifier,
            workingDirectory: workingDirectory
        )
        workers[projectID] = session

        broadcast(
            SupervisorEvent(
                type: "worker.started",
                projectID: projectID.uuidString,
                ticketID: nil,
                requestID: nil,
                pid: process.processIdentifier,
                text: nil,
                message: nil,
                success: nil,
                summary: nil,
                threadID: nil
            )
        )

        return session
    }

    private func consumeWorkerData(data: Data, projectID: UUID, source: StreamSource) {
        guard let session = workers[projectID] else { return }

        if data.isEmpty {
            return
        }

        let extracted: (lines: [String], remainder: Data)
        switch source {
        case .stdout:
            session.stdoutBuffer.append(data)
            extracted = Self.extractLines(from: session.stdoutBuffer)
            session.stdoutBuffer = extracted.remainder
        case .stderr:
            session.stderrBuffer.append(data)
            extracted = Self.extractLines(from: session.stderrBuffer)
            session.stderrBuffer = extracted.remainder
        }

        for line in extracted.lines {
            switch source {
            case .stdout:
                handleWorkerStdoutLine(line, projectID: projectID)
            case .stderr:
                handleWorkerStderrLine(line, projectID: projectID)
            }
        }
    }

    private func handleWorkerStdoutLine(_ line: String, projectID: UUID) {
        guard line.isEmpty == false else { return }

        guard
            let data = line.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            emitFallbackOutput(line: line, projectID: projectID)
            return
        }

        if let type = object["type"] as? String {
            handleSidecarTypedEvent(type: type, payload: object, projectID: projectID, rawLine: line)
            return
        }

        // Backward compatibility for legacy sidecar responses: {"ok":true|false,...}
        if object["ok"] as? Bool != nil {
            handleLegacySidecarResponse(payload: object, projectID: projectID, rawLine: line)
            return
        }

        emitFallbackOutput(line: line, projectID: projectID)
    }

    private func handleSidecarTypedEvent(type: String, payload: [String: Any], projectID: UUID, rawLine: String) {
        let requestID = parseUUID(payload["requestId"] as? String) ?? parseUUID(payload["requestID"] as? String)
        let activeRequest = resolveActiveRequest(projectID: projectID, requestID: requestID)

        switch type {
        case "ticket.started":
            guard let activeRequest else { return }
            broadcast(
                SupervisorEvent(
                    type: "ticket.started",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: nil,
                    success: nil,
                    summary: nil,
                    threadID: payload["threadId"] as? String ?? payload["threadID"] as? String
                )
            )

        case "ticket.output":
            guard let activeRequest else { return }
            let text = payload["text"] as? String ?? payload["line"] as? String ?? rawLine
            broadcast(
                SupervisorEvent(
                    type: "ticket.output",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: text,
                    message: nil,
                    success: nil,
                    summary: nil,
                    threadID: payload["threadId"] as? String ?? payload["threadID"] as? String
                )
            )
            broadcast(
                SupervisorEvent(
                    type: "task.output",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: text,
                    message: nil,
                    success: nil,
                    summary: nil,
                    threadID: payload["threadId"] as? String ?? payload["threadID"] as? String
                )
            )

        case "ticket.error":
            guard let activeRequest else { return }
            let message = payload["message"] as? String ?? payload["error"] as? String ?? "Unknown sidecar error"
            broadcast(
                SupervisorEvent(
                    type: "ticket.error",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: message,
                    success: nil,
                    summary: nil,
                    threadID: payload["threadId"] as? String ?? payload["threadID"] as? String
                )
            )

        case "ticket.completed":
            guard let activeRequest else { return }
            let success = payload["success"] as? Bool ?? false
            let summary = payload["summary"] as? String
                ?? payload["finalResponse"] as? String
                ?? payload["error"] as? String
            recordTaskCompletion(
                projectID: activeRequest.projectID,
                taskID: activeRequest.requestID,
                success: success,
                summary: summary
            )
            if success {
                emitTaskCompleted(
                    projectID: activeRequest.projectID,
                    ticketID: activeRequest.ticketID,
                    requestID: activeRequest.requestID,
                    summary: summary
                )
            } else {
                emitTaskFailed(
                    projectID: activeRequest.projectID,
                    ticketID: activeRequest.ticketID,
                    requestID: activeRequest.requestID,
                    message: summary ?? "Task failed."
                )
            }
            broadcast(
                SupervisorEvent(
                    type: "ticket.completed",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: nil,
                    success: success,
                    summary: summary,
                    threadID: payload["threadId"] as? String ?? payload["threadID"] as? String
                )
            )
            clearRequest(activeRequest)

        case "codex.event":
            guard let activeRequest else { return }
            if
                let eventPayload = payload["event"] as? [String: Any],
                let nestedType = eventPayload["type"] as? String
            {
                switch nestedType {
                case "turn.failed":
                    let message = extractErrorMessage(from: eventPayload) ?? "Codex turn failed."
                    recordTaskFailure(projectID: activeRequest.projectID, taskID: activeRequest.requestID, summary: message)
                    broadcast(
                        SupervisorEvent(
                            type: "ticket.error",
                            projectID: activeRequest.projectID.uuidString,
                            ticketID: activeRequest.ticketID.uuidString,
                            requestID: activeRequest.requestID.uuidString,
                            pid: nil,
                            text: nil,
                            message: message,
                            success: nil,
                            summary: nil,
                            threadID: nil
                        )
                    )
                    emitTaskFailed(
                        projectID: activeRequest.projectID,
                        ticketID: activeRequest.ticketID,
                        requestID: activeRequest.requestID,
                        message: message
                    )
                    broadcast(
                        SupervisorEvent(
                            type: "ticket.completed",
                            projectID: activeRequest.projectID.uuidString,
                            ticketID: activeRequest.ticketID.uuidString,
                            requestID: activeRequest.requestID.uuidString,
                            pid: nil,
                            text: nil,
                            message: nil,
                            success: false,
                            summary: message,
                            threadID: nil
                        )
                    )
                    clearRequest(activeRequest)
                    return

                case "turn.completed":
                    recordTaskCompletion(
                        projectID: activeRequest.projectID,
                        taskID: activeRequest.requestID,
                        success: true,
                        summary: nil
                    )
                    emitTaskCompleted(
                        projectID: activeRequest.projectID,
                        ticketID: activeRequest.ticketID,
                        requestID: activeRequest.requestID,
                        summary: nil
                    )
                    broadcast(
                        SupervisorEvent(
                            type: "ticket.completed",
                            projectID: activeRequest.projectID.uuidString,
                            ticketID: activeRequest.ticketID.uuidString,
                            requestID: activeRequest.requestID.uuidString,
                            pid: nil,
                            text: nil,
                            message: nil,
                            success: true,
                            summary: nil,
                            threadID: nil
                        )
                    )
                    clearRequest(activeRequest)
                    return

                case "turn.cancelled", "turn.canceled", "turn.aborted":
                    let message = "Codex turn was cancelled."
                    recordTaskFailure(projectID: activeRequest.projectID, taskID: activeRequest.requestID, summary: message)
                    broadcast(
                        SupervisorEvent(
                            type: "ticket.error",
                            projectID: activeRequest.projectID.uuidString,
                            ticketID: activeRequest.ticketID.uuidString,
                            requestID: activeRequest.requestID.uuidString,
                            pid: nil,
                            text: nil,
                            message: message,
                            success: nil,
                            summary: nil,
                            threadID: nil
                        )
                    )
                    emitTaskFailed(
                        projectID: activeRequest.projectID,
                        ticketID: activeRequest.ticketID,
                        requestID: activeRequest.requestID,
                        message: message
                    )
                    broadcast(
                        SupervisorEvent(
                            type: "ticket.completed",
                            projectID: activeRequest.projectID.uuidString,
                            ticketID: activeRequest.ticketID.uuidString,
                            requestID: activeRequest.requestID.uuidString,
                            pid: nil,
                            text: nil,
                            message: nil,
                            success: false,
                            summary: message,
                            threadID: nil
                        )
                    )
                    clearRequest(activeRequest)
                    return

                default:
                    break
                }
            }

        default:
            emitFallbackOutput(line: rawLine, projectID: projectID)
        }
    }

    private func handleLegacySidecarResponse(payload: [String: Any], projectID: UUID, rawLine: String) {
        guard let activeRequest = resolveActiveRequest(projectID: projectID, requestID: nil) else {
            return
        }

        let success = payload["ok"] as? Bool ?? false
        if success == false {
            let message = payload["error"] as? String ?? "Codex sidecar reported failure."
            recordTaskFailure(projectID: activeRequest.projectID, taskID: activeRequest.requestID, summary: message)
            broadcast(
                SupervisorEvent(
                    type: "ticket.error",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: message,
                    success: nil,
                    summary: nil,
                    threadID: nil
                )
            )
            emitTaskFailed(
                projectID: activeRequest.projectID,
                ticketID: activeRequest.ticketID,
                requestID: activeRequest.requestID,
                message: message
            )
        } else if
            let result = payload["result"] as? [String: Any],
            let finalResponse = result["finalResponse"] as? String,
            finalResponse.isEmpty == false
        {
            broadcast(
                SupervisorEvent(
                    type: "ticket.output",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: finalResponse,
                    message: nil,
                    success: nil,
                    summary: nil,
                    threadID: nil
                )
            )
            broadcast(
                SupervisorEvent(
                    type: "task.output",
                    projectID: activeRequest.projectID.uuidString,
                    ticketID: activeRequest.ticketID.uuidString,
                    requestID: activeRequest.requestID.uuidString,
                    pid: nil,
                    text: finalResponse,
                    message: nil,
                    success: nil,
                    summary: nil,
                    threadID: nil
                )
            )
        } else {
            emitFallbackOutput(line: rawLine, projectID: projectID)
        }

        if success {
            recordTaskCompletion(projectID: activeRequest.projectID, taskID: activeRequest.requestID, success: true, summary: nil)
            emitTaskCompleted(
                projectID: activeRequest.projectID,
                ticketID: activeRequest.ticketID,
                requestID: activeRequest.requestID,
                summary: nil
            )
        }

        broadcast(
            SupervisorEvent(
                type: "ticket.completed",
                projectID: activeRequest.projectID.uuidString,
                ticketID: activeRequest.ticketID.uuidString,
                requestID: activeRequest.requestID.uuidString,
                pid: nil,
                text: nil,
                message: nil,
                success: success,
                summary: payload["error"] as? String,
                threadID: nil
            )
        )
        clearRequest(activeRequest)
    }

    private func emitFallbackOutput(line: String, projectID: UUID) {
        guard let activeRequest = resolveActiveRequest(projectID: projectID, requestID: nil) else {
            return
        }

        broadcast(
            SupervisorEvent(
                type: "ticket.output",
                projectID: activeRequest.projectID.uuidString,
                ticketID: activeRequest.ticketID.uuidString,
                requestID: activeRequest.requestID.uuidString,
                pid: nil,
                text: line,
                message: nil,
                success: nil,
                summary: nil,
                threadID: nil
            )
        )
        broadcast(
            SupervisorEvent(
                type: "task.output",
                projectID: activeRequest.projectID.uuidString,
                ticketID: activeRequest.ticketID.uuidString,
                requestID: activeRequest.requestID.uuidString,
                pid: nil,
                text: line,
                message: nil,
                success: nil,
                summary: nil,
                threadID: nil
            )
        )
    }

    private func handleWorkerStderrLine(_ line: String, projectID: UUID) {
        guard line.isEmpty == false else { return }
        guard let activeRequest = resolveActiveRequest(projectID: projectID, requestID: nil) else { return }

        broadcast(
            SupervisorEvent(
                type: "ticket.error",
                projectID: activeRequest.projectID.uuidString,
                ticketID: activeRequest.ticketID.uuidString,
                requestID: activeRequest.requestID.uuidString,
                pid: nil,
                text: nil,
                message: line,
                success: nil,
                summary: nil,
                threadID: nil
            )
        )
    }

    private func resolveActiveRequest(projectID: UUID, requestID: UUID?) -> ActiveRequest? {
        if let requestID, let request = activeRequests[requestID] {
            return request
        }

        if let session = workers[projectID], let activeRequestID = session.activeRequestID {
            return activeRequests[activeRequestID]
        }

        return nil
    }

    private func clearRequest(_ request: ActiveRequest) {
        activeRequests.removeValue(forKey: request.requestID)
        runningTaskProcesses.removeValue(forKey: request.requestID)
        if let session = workers[request.projectID], session.activeRequestID == request.requestID {
            session.activeRequestID = nil
        }
    }

    private func handleWorkerTermination(projectID: UUID, statusCode: Int32) {
        guard let session = workers.removeValue(forKey: projectID) else { return }

        let activeRequestID = session.activeRequestID

        session.stdout.readabilityHandler = nil
        session.stderr.readabilityHandler = nil
        session.stdin.closeFile()
        session.stdout.closeFile()
        session.stderr.closeFile()

        if let activeRequestID, let request = activeRequests[activeRequestID] {
            let message = "Sidecar exited with status \(statusCode)."
            recordTaskFailure(projectID: request.projectID, taskID: request.requestID, summary: message)
            broadcast(
                SupervisorEvent(
                    type: "ticket.error",
                    projectID: request.projectID.uuidString,
                    ticketID: request.ticketID.uuidString,
                    requestID: request.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: message,
                    success: nil,
                    summary: nil,
                    threadID: nil
                )
            )
            emitTaskFailed(
                projectID: request.projectID,
                ticketID: request.ticketID,
                requestID: request.requestID,
                message: message
            )
            broadcast(
                SupervisorEvent(
                    type: "ticket.completed",
                    projectID: request.projectID.uuidString,
                    ticketID: request.ticketID.uuidString,
                    requestID: request.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: nil,
                    success: false,
                    summary: message,
                    threadID: nil
                )
            )
            clearRequest(request)
        }

        broadcast(
            SupervisorEvent(
                type: "worker.exited",
                projectID: projectID.uuidString,
                ticketID: nil,
                requestID: nil,
                pid: session.pid,
                text: nil,
                message: "Worker exited with status \(statusCode).",
                success: nil,
                summary: nil,
                threadID: nil
            )
        )
    }

    private func stopWorker(projectID: UUID, emitWorkerExit: Bool) {
        guard let session = workers.removeValue(forKey: projectID) else { return }

        session.stdout.readabilityHandler = nil
        session.stderr.readabilityHandler = nil

        if session.process.isRunning {
            session.process.terminate()
        }

        session.stdin.closeFile()
        session.stdout.closeFile()
        session.stderr.closeFile()

        if let activeRequestID = session.activeRequestID, let request = activeRequests[activeRequestID] {
            let message = "Worker stopped before completion."
            recordTaskFailure(projectID: request.projectID, taskID: request.requestID, summary: message)
            broadcast(
                SupervisorEvent(
                    type: "ticket.error",
                    projectID: request.projectID.uuidString,
                    ticketID: request.ticketID.uuidString,
                    requestID: request.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: message,
                    success: nil,
                    summary: nil,
                    threadID: nil
                )
            )
            emitTaskFailed(
                projectID: request.projectID,
                ticketID: request.ticketID,
                requestID: request.requestID,
                message: message
            )
            broadcast(
                SupervisorEvent(
                    type: "ticket.completed",
                    projectID: request.projectID.uuidString,
                    ticketID: request.ticketID.uuidString,
                    requestID: request.requestID.uuidString,
                    pid: nil,
                    text: nil,
                    message: nil,
                    success: false,
                    summary: message,
                    threadID: nil
                )
            )
            clearRequest(request)
        }

        if emitWorkerExit {
            broadcast(
                SupervisorEvent(
                    type: "worker.exited",
                    projectID: projectID.uuidString,
                    ticketID: nil,
                    requestID: nil,
                    pid: session.pid,
                    text: nil,
                    message: "Worker stopped by supervisor request.",
                    success: nil,
                    summary: nil,
                    threadID: nil
                )
            )
        }
    }

    private var taskDataRootURL: URL {
        URL(fileURLWithPath: runtimeDirectory).appendingPathComponent("tasks", isDirectory: true)
    }

    private func projectDirectoryURL(projectID: UUID) -> URL {
        taskDataRootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private func eventsFileURL(projectID: UUID) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent("events.jsonl", isDirectory: false)
    }

    private func tasksFileURL(projectID: UUID) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent("tasks.json", isDirectory: false)
    }

    private func metaFileURL(projectID: UUID) -> URL {
        projectDirectoryURL(projectID: projectID).appendingPathComponent("meta.json", isDirectory: false)
    }

    private func preparePersistenceDirectories() throws {
        try fileManager.createDirectory(at: taskDataRootURL, withIntermediateDirectories: true)
    }

    private func loadPersistedProjectState() throws {
        guard fileManager.fileExists(atPath: taskDataRootURL.path) else { return }
        let entries = try fileManager.contentsOfDirectory(at: taskDataRootURL, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()

        for entry in entries {
            guard entry.hasDirectoryPath, let projectID = UUID(uuidString: entry.lastPathComponent) else { continue }

            let metaURL = metaFileURL(projectID: projectID)
            if
                fileManager.fileExists(atPath: metaURL.path),
                let data = try? Data(contentsOf: metaURL),
                let decodedMeta = try? decoder.decode(ProjectLogMeta.self, from: data)
            {
                projectMeta[projectID] = decodedMeta
            } else {
                projectMeta[projectID] = ProjectLogMeta(
                    nextEventID: inferNextEventID(projectID: projectID),
                    lastAckedEventID: 0
                )
            }

            let tasksURL = tasksFileURL(projectID: projectID)
            if
                fileManager.fileExists(atPath: tasksURL.path),
                let data = try? Data(contentsOf: tasksURL),
                let decodedTasks = try? decoder.decode([TaskStatusEntry].self, from: data)
            {
                var byID: [UUID: TaskStatusEntry] = [:]
                var byIdempotency: [String: UUID] = [:]

                for task in decodedTasks {
                    guard let taskID = UUID(uuidString: task.taskID) else { continue }
                    byID[taskID] = task
                    if let idempotencyKey = task.idempotencyKey {
                        byIdempotency[idempotencyKey] = taskID
                    }
                }

                taskRecords[projectID] = byID
                idempotencyIndex[projectID] = byIdempotency
            }
        }
    }

    private func inferNextEventID(projectID: UUID) -> Int64 {
        let url = eventsFileURL(projectID: projectID)
        guard let data = try? Data(contentsOf: url), data.isEmpty == false else { return 1 }

        let decoder = JSONDecoder()
        var maxEventID: Int64 = 0
        for line in Self.extractLines(from: data).lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let event = try? decoder.decode(SupervisorEvent.self, from: lineData) else { continue }
            if let eventID = event.eventID {
                maxEventID = max(maxEventID, eventID)
            }
        }
        return maxEventID + 1
    }

    private func ensureProjectPersistenceDirectory(projectID: UUID) throws {
        try fileManager.createDirectory(
            at: projectDirectoryURL(projectID: projectID),
            withIntermediateDirectories: true
        )
    }

    private func persistTaskRecords(projectID: UUID) throws {
        try ensureProjectPersistenceDirectory(projectID: projectID)
        let tasks = Array((taskRecords[projectID] ?? [:]).values).sorted { $0.startedAtEpochMS < $1.startedAtEpochMS }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tasks)
        try data.write(to: tasksFileURL(projectID: projectID), options: .atomic)
    }

    private func persistProjectMeta(projectID: UUID) throws {
        try ensureProjectPersistenceDirectory(projectID: projectID)
        guard let meta = projectMeta[projectID] else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: metaFileURL(projectID: projectID), options: .atomic)
    }

    private func findDeduplicatedTask(projectID: UUID, idempotencyKey: String?) -> UUID? {
        guard let idempotencyKey else { return nil }
        return idempotencyIndex[projectID]?[idempotencyKey]
    }

    private func recordTaskAccepted(
        projectID: UUID,
        taskID: UUID,
        ticketID: UUID?,
        kind: String,
        idempotencyKey: String?
    ) {
        var projectTasks = taskRecords[projectID] ?? [:]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        projectTasks[taskID] = TaskStatusEntry(
            projectID: projectID.uuidString,
            taskID: taskID.uuidString,
            ticketID: ticketID?.uuidString,
            kind: kind,
            state: "running",
            idempotencyKey: idempotencyKey,
            startedAtEpochMS: now,
            completedAtEpochMS: nil,
            success: nil,
            summary: nil
        )
        taskRecords[projectID] = projectTasks
        if let idempotencyKey {
            var projectKeys = idempotencyIndex[projectID] ?? [:]
            projectKeys[idempotencyKey] = taskID
            idempotencyIndex[projectID] = projectKeys
        }

        do {
            try persistTaskRecords(projectID: projectID)
        } catch {
            fputs("Warning: failed to persist task records for \(projectID): \(error.localizedDescription)\n", stderr)
        }
    }

    private func recordTaskCompletion(projectID: UUID, taskID: UUID, success: Bool, summary: String?) {
        guard var projectTasks = taskRecords[projectID], var task = projectTasks[taskID] else { return }
        task.state = success ? "completed" : "failed"
        task.success = success
        task.summary = summary
        task.completedAtEpochMS = Int64(Date().timeIntervalSince1970 * 1000)
        projectTasks[taskID] = task
        taskRecords[projectID] = projectTasks

        do {
            try persistTaskRecords(projectID: projectID)
        } catch {
            fputs("Warning: failed to persist task records for \(projectID): \(error.localizedDescription)\n", stderr)
        }
    }

    private func recordTaskFailure(projectID: UUID, taskID: UUID, summary: String) {
        recordTaskCompletion(projectID: projectID, taskID: taskID, success: false, summary: summary)
    }

    private func emitTaskAccepted(projectID: UUID, ticketID: UUID?, requestID: UUID) {
        broadcast(
            SupervisorEvent(
                type: "task.accepted",
                eventID: nil,
                timestampEpochMS: nil,
                projectID: projectID.uuidString,
                ticketID: ticketID?.uuidString,
                requestID: requestID.uuidString,
                pid: nil,
                text: nil,
                message: nil,
                success: nil,
                summary: nil,
                threadID: nil
            )
        )
    }

    private func emitTaskFailed(
        projectID: UUID,
        ticketID: UUID?,
        requestID: UUID,
        message: String,
        timestampEpochMS: Int64? = nil
    ) {
        broadcast(
            SupervisorEvent(
                type: "task.failed",
                eventID: nil,
                timestampEpochMS: timestampEpochMS,
                projectID: projectID.uuidString,
                ticketID: ticketID?.uuidString,
                requestID: requestID.uuidString,
                pid: nil,
                text: nil,
                message: message,
                success: false,
                summary: message,
                threadID: nil
            )
        )
    }

    private func emitTaskCompleted(projectID: UUID, ticketID: UUID?, requestID: UUID, summary: String?) {
        broadcast(
            SupervisorEvent(
                type: "task.completed",
                eventID: nil,
                timestampEpochMS: nil,
                projectID: projectID.uuidString,
                ticketID: ticketID?.uuidString,
                requestID: requestID.uuidString,
                pid: nil,
                text: nil,
                message: nil,
                success: true,
                summary: summary,
                threadID: nil
            )
        )
    }

    private func replayEvents(projectID: UUID, fromEventID: Int64, to fd: Int32) throws {
        let url = eventsFileURL(projectID: projectID)
        guard let data = try? Data(contentsOf: url), data.isEmpty == false else { return }

        let decoder = JSONDecoder()
        for line in Self.extractLines(from: data).lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let event = try? decoder.decode(SupervisorEvent.self, from: lineData) else { continue }
            guard let eventID = event.eventID, eventID >= fromEventID else { continue }
            guard sendJSON(event, to: fd) else {
                throw SupervisorError.sendFailed("Failed replaying events to subscriber.")
            }
        }
    }

    private func appendEventToLog(_ event: SupervisorEvent, projectID: UUID) {
        do {
            try ensureProjectPersistenceDirectory(projectID: projectID)
            var payload = try JSONEncoder().encode(event)
            payload.append(0x0A)
            let url = eventsFileURL(projectID: projectID)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: url, options: .atomic)
            }
            try pruneEventLogIfNeeded(projectID: projectID)
        } catch {
            fputs("Warning: failed to append event log for \(projectID): \(error.localizedDescription)\n", stderr)
        }
    }

    private func pruneEventLogIfNeeded(projectID: UUID) throws {
        let url = eventsFileURL(projectID: projectID)
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return
        }

        if fileSize.intValue <= Self.maxEventLogBytes {
            return
        }

        guard let data = try? Data(contentsOf: url), data.isEmpty == false else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoff = now - Self.maxEventAgeMS

        let decoder = JSONDecoder()
        var events: [SupervisorEvent] = []
        for line in Self.extractLines(from: data).lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let event = try? decoder.decode(SupervisorEvent.self, from: lineData) else { continue }
            if let timestamp = event.timestampEpochMS, timestamp < cutoff {
                continue
            }
            events.append(event)
        }

        let encoder = JSONEncoder()
        var retained = events
        while retained.count > 1 {
            let encoded = try retained.reduce(into: Data()) { partial, event in
                try partial.append(encoder.encode(event))
                partial.append(0x0A)
            }
            if encoded.count <= Self.maxEventLogBytes {
                try encoded.write(to: url, options: .atomic)
                return
            }
            retained.removeFirst()
        }
    }

    private func broadcast(_ event: SupervisorEvent) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var eventToSend = event
        if eventToSend.timestampEpochMS == nil {
            eventToSend = SupervisorEvent(
                type: event.type,
                eventID: event.eventID,
                timestampEpochMS: now,
                projectID: event.projectID,
                ticketID: event.ticketID,
                requestID: event.requestID,
                pid: event.pid,
                text: event.text,
                message: event.message,
                success: event.success,
                summary: event.summary,
                threadID: event.threadID
            )
        }

        if
            let projectIDRaw = eventToSend.projectID,
            let projectID = UUID(uuidString: projectIDRaw)
        {
            var meta = projectMeta[projectID] ?? ProjectLogMeta(nextEventID: 1, lastAckedEventID: 0)
            let assignedEventID = meta.nextEventID
            meta.nextEventID += 1
            projectMeta[projectID] = meta
            try? persistProjectMeta(projectID: projectID)

            eventToSend = SupervisorEvent(
                type: eventToSend.type,
                eventID: assignedEventID,
                timestampEpochMS: eventToSend.timestampEpochMS,
                projectID: eventToSend.projectID,
                ticketID: eventToSend.ticketID,
                requestID: eventToSend.requestID,
                pid: eventToSend.pid,
                text: eventToSend.text,
                message: eventToSend.message,
                success: eventToSend.success,
                summary: eventToSend.summary,
                threadID: eventToSend.threadID
            )
            appendEventToLog(eventToSend, projectID: projectID)
        }

        var deadSubscribers: [Int32] = []
        for (subscriberFD, subscriber) in subscribers {
            if let filteredProjectID = subscriber.projectID {
                guard eventToSend.projectID == filteredProjectID.uuidString else { continue }
            }

            if sendJSON(eventToSend, to: subscriberFD) == false {
                deadSubscribers.append(subscriberFD)
            }
        }

        if deadSubscribers.isEmpty == false {
            for fd in deadSubscribers {
                subscribers.removeValue(forKey: fd)
                Darwin.close(fd)
            }
        }
    }

    private func parseUUID(_ rawValue: String?) -> UUID? {
        guard let rawValue else { return nil }
        return UUID(uuidString: rawValue)
    }

    private func firstInFlightRequest(projectID: UUID, excluding taskID: UUID) -> ActiveRequest? {
        activeRequests.values.first { request in
            request.projectID == projectID && request.requestID != taskID
        }
    }

    private func extractErrorMessage(from payload: [String: Any]) -> String? {
        if let message = payload["message"] as? String {
            return message
        }
        if
            let error = payload["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        return nil
    }

    private func resolveWorkingDirectory(_ rawWorkingDirectory: String) throws -> String {
        let trimmed = rawWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw SupervisorError.invalidWorkingDirectory(rawWorkingDirectory)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SupervisorError.invalidWorkingDirectory(expanded)
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func resolveSidecarScriptPath() throws -> String {
        let normalized = URL(fileURLWithPath: sidecarScriptPath).standardizedFileURL.path
        guard fileManager.fileExists(atPath: normalized) else {
            throw SupervisorError.missingSidecarScript(normalized)
        }
        return normalized
    }

    private func resolveNodeExecutablePath() throws -> String {
        if let nodeBinaryPath {
            guard fileManager.isExecutableFile(atPath: nodeBinaryPath) else {
                throw SupervisorError.missingNodeBinary
            }
            return nodeBinaryPath
        }

        let explicitNode = ProcessInfo.processInfo.environment["NODE_BINARY"]
            .map { ($0 as NSString).expandingTildeInPath }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        let hardcodedCandidates = [
            explicitNode,
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].compactMap { $0 }

        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let defaultEntries = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let searchedEntries = Array(Set(pathEntries + defaultEntries))

        let pathCandidates = searchedEntries.map { entry in
            URL(fileURLWithPath: entry).appendingPathComponent("node").path
        }

        let allCandidates = hardcodedCandidates + pathCandidates
        for candidate in allCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw SupervisorError.missingNodeBinary
    }

    private func sendError(_ message: String, to fd: Int32) -> Bool {
        sendJSON(ErrorResponse(message: message), to: fd)
    }

    private func sendJSON<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
        do {
            var payload = try JSONEncoder().encode(value)
            payload.append(0x0A)
            return writeAll(payload, to: fd)
        } catch {
            return false
        }
    }

    private func readLine(from fd: Int32, maxBytes: Int = 65536) -> String? {
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

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
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

    private static func extractLines(from data: Data) -> (lines: [String], remainder: Data) {
        var lines: [String] = []
        var startIndex = data.startIndex

        while let newlineIndex = data[startIndex...].firstIndex(of: 0x0A) {
            var lineData = data[startIndex ..< newlineIndex]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            let line = String(decoding: lineData, as: UTF8.self)
            lines.append(line)
            startIndex = data.index(after: newlineIndex)
        }

        return (lines, Data(data[startIndex...]))
    }

    private func setTimeout(fd: Int32, option: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, option, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private func setNoSigPipe(fd: Int32) {
        #if os(macOS)
            var enabled: Int32 = 1
            _ = withUnsafePointer(to: &enabled) { pointer in
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
            }
        #endif
    }

    private static func splitOutput(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func summaryDescription(_ rawDescription: String) -> String {
        let normalized = rawDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return "(none)"
        }
        if normalized.count <= 240 {
            return normalized
        }
        let index = normalized.index(normalized.startIndex, offsetBy: 240)
        return String(normalized[..<index]) + "..."
    }
}

private final class SupervisorRuntime {
    private let configuration: SupervisorConfiguration
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "io.kelan.ticketparty.codex-supervisor.signals")
    private var signalSources: [DispatchSourceSignal] = []
    private var didShutdown = false
    private var controlServer: ControlServer?

    init(configuration: SupervisorConfiguration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    func run() throws -> Never {
        try prepareRuntimeDirectory()
        let token = UUID().uuidString

        let server = ControlServer(
            runtimeDirectory: configuration.runtimeDirectory,
            socketPath: configuration.socketPath,
            protocolVersion: configuration.protocolVersion,
            instanceToken: token,
            sidecarScriptPath: configuration.sidecarScriptPath,
            nodeBinaryPath: configuration.nodeBinaryPath,
            fileManager: fileManager
        )
        do {
            try server.start()
            controlServer = server
        } catch {
            throw SupervisorError.failedToStartControlServer(error.localizedDescription)
        }

        try writeRuntimeRecord(instanceToken: token)
        installSignalHandlers()

        print("codex-supervisor started")
        print("pid=\(getpid())")
        print("runtime=\(configuration.runtimeDirectory)")
        print("record=\(configuration.recordPath)")
        print("socket=\(configuration.socketPath)")
        print("instanceToken=\(token)")
        fflush(stdout)

        dispatchMain()
    }

    private func prepareRuntimeDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: configuration.runtimeDirectory),
                withIntermediateDirectories: true
            )
        } catch {
            throw SupervisorError.failedToCreateDirectory(error.localizedDescription)
        }
    }

    private func writeRuntimeRecord(instanceToken: String) throws {
        let recordURL = URL(fileURLWithPath: configuration.recordPath)
        let parentDirectory = recordURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw SupervisorError.failedToCreateDirectory(error.localizedDescription)
        }

        let record = SupervisorRuntimeRecord(
            pid: getpid(),
            startedAtEpochMS: Int64(Date().timeIntervalSince1970 * 1000),
            protocolVersion: configuration.protocolVersion,
            binaryPath: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
            binaryHash: nil,
            controlEndpoint: configuration.socketPath,
            instanceToken: instanceToken
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(record)
            try data.write(to: recordURL, options: .atomic)
        } catch {
            throw SupervisorError.failedToWriteRuntimeRecord(error.localizedDescription)
        }
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.shutdown(exitCode: 0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown(exitCode: Int32) {
        guard didShutdown == false else { return }
        didShutdown = true

        controlServer?.stop()
        controlServer = nil

        let recordURL = URL(fileURLWithPath: configuration.recordPath)
        if fileManager.fileExists(atPath: recordURL.path) {
            do {
                try fileManager.removeItem(at: recordURL)
            } catch {
                fputs(
                    "Warning: \(SupervisorError.failedToDeleteRuntimeRecord(error.localizedDescription).localizedDescription)\n",
                    stderr
                )
            }
        }

        fflush(stdout)
        fflush(stderr)
        Darwin.exit(exitCode)
    }
}

private func printUsage() {
    print(
        """
        codex-supervisor - TicketParty Codex supervisor control server

        Options:
          --runtime-dir <path>      Runtime directory (default: ~/Library/Application Support/TicketParty/runtime)
          --record-path <path>      Supervisor runtime record path
          --socket-path <path>      Control socket path written in runtime record
          --protocol-version <int>  Protocol version for handshake metadata (default: 2)
          --sidecar-script <path>   Sidecar script path (default: ~/dev/codex-sidecar/sidecar.mjs)
          --node-binary <path>      Node executable path (optional)
          --help                    Show help
        """
    )
}

do {
    let config = try SupervisorConfiguration.make(arguments: Array(CommandLine.arguments.dropFirst()))
    let runtime = SupervisorRuntime(configuration: config)
    try runtime.run()
} catch {
    fputs("codex-supervisor failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
