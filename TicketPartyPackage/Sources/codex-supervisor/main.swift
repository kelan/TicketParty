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

private enum SupervisorError: LocalizedError {
    case invalidArgument(String)
    case failedToCreateDirectory(String)
    case failedToWriteRuntimeRecord(String)
    case failedToDeleteRuntimeRecord(String)

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
        }
    }
}

private final class SupervisorRuntime {
    private let configuration: SupervisorConfiguration
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "io.kelan.ticketparty.codex-supervisor.signals")
    private var signalSources: [DispatchSourceSignal] = []
    private var didShutdown = false

    init(configuration: SupervisorConfiguration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    func run() throws -> Never {
        try prepareRuntimeDirectory()
        let token = UUID().uuidString
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
