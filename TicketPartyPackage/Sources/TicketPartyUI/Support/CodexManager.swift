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
        case ticketOutput(ticketID: UUID, line: String)
        case ticketError(ticketID: UUID, message: String)
    }

    enum ManagerError: LocalizedError {
        case missingWorkingDirectory
        case invalidWorkingDirectory(String)
        case missingSidecarScript(String)
        case sidecarLaunchFailed(String)
        case stdinUnavailable
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingWorkingDirectory:
                return "Project working directory is required before sending to Codex."
            case let .invalidWorkingDirectory(path):
                return "Project working directory is invalid: \(path)"
            case let .missingSidecarScript(path):
                return "Codex sidecar script not found: \(path)"
            case let .sidecarLaunchFailed(message):
                return "Failed to launch Codex sidecar: \(message)"
            case .stdinUnavailable:
                return "Codex sidecar stdin is unavailable."
            case let .writeFailed(message):
                return "Failed to send prompt to Codex sidecar: \(message)"
            }
        }
    }

    private struct SidecarCommand: Encodable {
        let threadId: String
        let prompt: String
    }

    private struct Session {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stderr: FileHandle
    }

    private struct LineBuffer {
        var stdout: Data = .init()
        var stderr: Data = .init()
    }

    enum StreamSource {
        case stdout
        case stderr
    }

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let sidecarScriptPath: String
    private let fileManager: FileManager
    private var sessions: [UUID: Session] = [:]
    private var statuses: [UUID: CodexProjectStatus] = [:]
    private var activeTicketByProject: [UUID: UUID] = [:]
    private var lineBuffers: [UUID: LineBuffer] = [:]

    init(
        sidecarScriptPath: String = "~/dev/codex-sidecar/sidecar.mjs",
        fileManager: FileManager = .default
    ) {
        var streamContinuation: AsyncStream<Event>.Continuation?
        events = AsyncStream<Event> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation!
        self.sidecarScriptPath = sidecarScriptPath
        self.fileManager = fileManager
    }

    deinit {
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
    ) throws {
        let resolvedWorkingDirectory = try resolveWorkingDirectory(workingDirectory)
        try ensureSession(projectID: projectID, workingDirectory: resolvedWorkingDirectory)

        activeTicketByProject[projectID] = ticketID

        let payload = SidecarCommand(
            threadId: ticketID.uuidString,
            prompt: "\(title)\n\(description)"
        )

        let encoder = JSONEncoder()
        var data = try encoder.encode(payload)
        data.append(0x0A)

        guard let session = sessions[projectID] else {
            throw ManagerError.stdinUnavailable
        }

        do {
            try session.stdin.write(contentsOf: data)
        } catch {
            throw ManagerError.writeFailed(error.localizedDescription)
        }
    }

    private func ensureSession(projectID: UUID, workingDirectory: String) throws {
        if let session = sessions[projectID], session.process.isRunning {
            return
        }

        if let existing = sessions.removeValue(forKey: projectID) {
            existing.stdout.readabilityHandler = nil
            existing.stderr.readabilityHandler = nil
            existing.process.terminationHandler = nil
            existing.stdin.closeFile()
            existing.stdout.closeFile()
            existing.stderr.closeFile()
        }

        let sidecarScript = try resolveSidecarScriptPath()

        setStatus(.starting, for: projectID)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", sidecarScript]
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
            let data = handle.availableData
            Task { await self?.consume(data: data, projectID: projectID, source: .stdout) }
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consume(data: data, projectID: projectID, source: .stderr) }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleTermination(
                    projectID: projectID,
                    statusCode: terminatedProcess.terminationStatus
                )
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            setStatus(.error("Failed to launch sidecar process."), for: projectID)
            throw ManagerError.sidecarLaunchFailed(error.localizedDescription)
        }

        sessions[projectID] = Session(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutHandle,
            stderr: stderrHandle
        )
        lineBuffers[projectID] = LineBuffer()
        setStatus(.running, for: projectID)
    }

    private func consume(data: Data, projectID: UUID, source: StreamSource) {
        guard data.isEmpty == false else { return }

        var buffer = lineBuffers[projectID] ?? LineBuffer()
        let extracted: (lines: [String], remainder: Data)

        switch source {
        case .stdout:
            buffer.stdout.append(data)
            extracted = Self.extractLines(from: buffer.stdout)
            buffer.stdout = extracted.remainder
        case .stderr:
            buffer.stderr.append(data)
            extracted = Self.extractLines(from: buffer.stderr)
            buffer.stderr = extracted.remainder
        }

        lineBuffers[projectID] = buffer

        for line in extracted.lines {
            guard let ticketID = activeTicketByProject[projectID] else { continue }

            switch source {
            case .stdout:
                continuation.yield(.ticketOutput(ticketID: ticketID, line: line))
            case .stderr:
                continuation.yield(.ticketError(ticketID: ticketID, message: line))
            }
        }
    }

    private func handleTermination(projectID: UUID, statusCode: Int32) {
        guard let session = sessions.removeValue(forKey: projectID) else { return }

        session.stdout.readabilityHandler = nil
        session.stderr.readabilityHandler = nil
        session.stdin.closeFile()
        session.stdout.closeFile()
        session.stderr.closeFile()

        flushRemainders(for: projectID)
        lineBuffers.removeValue(forKey: projectID)

        if statusCode == 0 {
            setStatus(.stopped, for: projectID)
        } else {
            let message = "Sidecar exited with status \(statusCode)."
            setStatus(.error(message), for: projectID)
            if let ticketID = activeTicketByProject[projectID] {
                continuation.yield(.ticketError(ticketID: ticketID, message: message))
            }
        }
    }

    private func flushRemainders(for projectID: UUID) {
        guard let buffer = lineBuffers[projectID] else { return }
        guard let ticketID = activeTicketByProject[projectID] else { return }

        if buffer.stdout.isEmpty == false {
            let line = String(decoding: buffer.stdout, as: UTF8.self)
            continuation.yield(.ticketOutput(ticketID: ticketID, line: line))
        }

        if buffer.stderr.isEmpty == false {
            let line = String(decoding: buffer.stderr, as: UTF8.self)
            continuation.yield(.ticketError(ticketID: ticketID, message: line))
        }
    }

    private func setStatus(_ status: CodexProjectStatus, for projectID: UUID) {
        statuses[projectID] = status
        continuation.yield(.statusChanged(projectID: projectID, status: status))
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

    private func resolveSidecarScriptPath() throws -> String {
        let expanded = (sidecarScriptPath as NSString).expandingTildeInPath
        guard fileManager.fileExists(atPath: expanded) else {
            throw ManagerError.missingSidecarScript(expanded)
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
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

        let remainder = Data(data[startIndex...])
        return (lines, remainder)
    }
}

@MainActor
@Observable
final class CodexViewModel {
    private let manager: CodexManager
    private var eventTask: Task<Void, Never>?

    var projectStatuses: [UUID: CodexProjectStatus] = [:]
    var ticketOutput: [UUID: String] = [:]
    var ticketErrors: [UUID: String] = [:]

    init(manager: CodexManager = CodexManager()) {
        self.manager = manager
        eventTask = Task { [manager, weak self] in
            for await event in manager.events {
                guard let self else { return }
                await MainActor.run {
                    self.consume(event)
                }
            }
        }
    }

    func send(ticket: Ticket, project: Project) async {
        let projectID = project.id
        let workingDirectory = project.workingDirectory
        let ticketID = ticket.id
        let title = ticket.title
        let description = ticket.ticketDescription

        ticketErrors[ticketID] = nil

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
        }
    }

    func status(for projectID: UUID) -> CodexProjectStatus {
        projectStatuses[projectID] ?? .stopped
    }

    func output(for ticketID: UUID) -> String {
        ticketOutput[ticketID, default: ""]
    }

    private func consume(_ event: CodexManager.Event) {
        switch event {
        case let .statusChanged(projectID, status):
            projectStatuses[projectID] = status

        case let .ticketOutput(ticketID, line):
            var updatedOutput = ticketOutput[ticketID, default: ""]
            if updatedOutput.isEmpty {
                updatedOutput = line
            } else {
                updatedOutput += "\n"
                updatedOutput += line
            }
            ticketOutput[ticketID] = updatedOutput

        case let .ticketError(ticketID, message):
            ticketErrors[ticketID] = message
        }
    }
}
