import Darwin
import Dispatch
import Foundation

private struct SupervisorConfiguration {
    let runtimeDirectory: String
    let recordPath: String
    let socketPath: String
    let protocolVersion: Int

    static func make(arguments: [String]) throws -> SupervisorConfiguration {
        let defaultRuntime = "~/Library/Application Support/TicketParty/runtime"
        let defaultRecord = "\(defaultRuntime)/supervisor.json"
        let defaultSocket = "\(defaultRuntime)/supervisor.sock"

        var runtimeDirectory = defaultRuntime
        var recordPath = defaultRecord
        var socketPath = defaultSocket
        var protocolVersion = 1

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
            protocolVersion: protocolVersion
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
}

private struct HelloResponse: Encodable {
    let type = "hello.ok"
    let pid: Int32
    let protocolVersion: Int
    let instanceToken: String
    let serverTimeEpochMS: Int64
}

private struct ErrorResponse: Encodable {
    let type = "error"
    let message: String
}

private enum SupervisorError: LocalizedError {
    case invalidArgument(String)
    case failedToCreateDirectory(String)
    case failedToWriteRuntimeRecord(String)
    case failedToDeleteRuntimeRecord(String)
    case failedToStartControlServer(String)
    case invalidSocketPath(String)

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
        }
    }
}

private final class ControlServer {
    private let socketPath: String
    private let protocolVersion: Int
    private let instanceToken: String
    private let queue = DispatchQueue(label: "io.kelan.ticketparty.codex-supervisor.control")
    private var listeningFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(socketPath: String, protocolVersion: Int, instanceToken: String) {
        self.socketPath = socketPath
        self.protocolVersion = protocolVersion
        self.instanceToken = instanceToken
    }

    func start() throws {
        let socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
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
        readSource?.cancel()
        readSource = nil

        if listeningFD >= 0 {
            Darwin.close(listeningFD)
            listeningFD = -1
        }

        unlink(socketPath)
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
        defer {
            Darwin.close(fd)
        }

        setNoSigPipe(fd: fd)
        setTimeout(fd: fd, option: SO_RCVTIMEO, seconds: 2)
        setTimeout(fd: fd, option: SO_SNDTIMEO, seconds: 2)

        guard let requestLine = readLine(from: fd) else {
            _ = sendError("Failed to read request.", to: fd)
            return
        }

        guard let requestData = requestLine.data(using: .utf8) else {
            _ = sendError("Request was not UTF-8.", to: fd)
            return
        }

        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: requestData)
        } catch {
            _ = sendError("Invalid request JSON: \(error.localizedDescription)", to: fd)
            return
        }

        switch request.type {
        case "hello":
            handleHello(request: request, fd: fd)
        default:
            _ = sendError("Unknown request type '\(request.type)'.", to: fd)
        }
    }

    private func handleHello(request: ControlRequest, fd: Int32) {
        let minimumProtocol = request.minProtocolVersion ?? 1
        if protocolVersion < minimumProtocol {
            _ = sendError("Protocol version \(protocolVersion) is below required minimum \(minimumProtocol).", to: fd)
            return
        }

        if let expectedToken = request.expectedInstanceToken, expectedToken != instanceToken {
            _ = sendError("Instance token mismatch.", to: fd)
            return
        }

        let response = HelloResponse(
            pid: getpid(),
            protocolVersion: protocolVersion,
            instanceToken: instanceToken,
            serverTimeEpochMS: Int64(Date().timeIntervalSince1970 * 1000)
        )
        _ = sendJSON(response, to: fd)
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

    private func readLine(from fd: Int32, maxBytes: Int = 16384) -> String? {
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
            instanceToken: token
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
        codex-supervisor - TicketParty Codex supervisor scaffold

        Options:
          --runtime-dir <path>      Runtime directory (default: ~/Library/Application Support/TicketParty/runtime)
          --record-path <path>      Supervisor runtime record path
          --socket-path <path>      Control socket path written in runtime record
          --protocol-version <int>  Protocol version for handshake metadata
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
