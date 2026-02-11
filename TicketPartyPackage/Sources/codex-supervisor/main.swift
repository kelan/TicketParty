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

private struct SupervisorEvent: Encodable {
    let type: String
    let projectID: String?
    let ticketID: String?
    let requestID: String?
    let pid: Int32?
    let text: String?
    let message: String?
    let success: Bool?
    let summary: String?
    let threadID: String?
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
}

private enum StreamSource {
    case stdout
    case stderr
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
    private let socketPath: String
    private let protocolVersion: Int
    private let instanceToken: String
    private let sidecarScriptPath: String
    private let nodeBinaryPath: String?
    private let fileManager: FileManager

    private let queue = DispatchQueue(label: "io.kelan.ticketparty.codex-supervisor.control")
    private var listeningFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var subscribers: [Int32: Bool] = [:]
    private var workers: [UUID: WorkerSession] = [:]
    private var activeRequests: [UUID: ActiveRequest] = [:]

    init(
        socketPath: String,
        protocolVersion: Int,
        instanceToken: String,
        sidecarScriptPath: String,
        nodeBinaryPath: String?,
        fileManager: FileManager = .default
    ) {
        self.socketPath = socketPath
        self.protocolVersion = protocolVersion
        self.instanceToken = instanceToken
        self.sidecarScriptPath = sidecarScriptPath
        self.nodeBinaryPath = nodeBinaryPath
        self.fileManager = fileManager
    }

    func start() throws {
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
                try handleSubscribe(fd: fd)
                return true
            case "sendTicket":
                try handleSendTicket(request: request, fd: fd)
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

    private func handleSubscribe(fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        guard sendJSON(AckResponse(type: "subscribe.ok", message: nil), to: fd) else {
            throw SupervisorError.sendFailed("Failed to confirm subscription.")
        }

        subscribers[fd] = true
    }

    private func handleSendTicket(request: ControlRequest, fd: Int32) throws {
        guard
            let projectIDRaw = request.projectID,
            let ticketIDRaw = request.ticketID,
            let requestIDRaw = request.requestID,
            let prompt = request.prompt,
            let workingDirectory = request.workingDirectory
        else {
            throw SupervisorError.invalidRequest(
                "sendTicket requires projectID, ticketID, requestID, workingDirectory, and prompt."
            )
        }

        guard
            let projectID = UUID(uuidString: projectIDRaw),
            let ticketID = UUID(uuidString: ticketIDRaw),
            let requestID = UUID(uuidString: requestIDRaw)
        else {
            throw SupervisorError.invalidRequest("sendTicket IDs must be valid UUID strings.")
        }

        let resolvedWorkingDirectory = try resolveWorkingDirectory(workingDirectory)
        let session = try ensureWorker(projectID: projectID, workingDirectory: resolvedWorkingDirectory)

        if let existingRequestID = session.activeRequestID, existingRequestID != requestID {
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
            requestId: requestID.uuidString,
            prompt: prompt
        )
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)

        do {
            try session.stdin.write(contentsOf: data)
        } catch {
            throw SupervisorError.sendFailed(error.localizedDescription)
        }

        session.activeRequestID = requestID
        activeRequests[requestID] = ActiveRequest(requestID: requestID, projectID: projectID, ticketID: ticketID)

        _ = sendJSON(AckResponse(type: "sendTicket.ok", message: nil), to: fd)
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
        } else {
            emitFallbackOutput(line: rawLine, projectID: projectID)
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

    private func broadcast(_ event: SupervisorEvent) {
        var deadSubscribers: [Int32] = []
        for (subscriberFD, _) in subscribers {
            if sendJSON(event, to: subscriberFD) == false {
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
