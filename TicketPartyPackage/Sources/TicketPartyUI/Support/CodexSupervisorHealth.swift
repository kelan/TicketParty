import Darwin
import Foundation

enum CodexSupervisorHealthStatus: Sendable, Equatable {
    case healthy(pid: Int32, protocolVersion: Int)
    case notRunning
    case staleRecord(pid: Int32)
    case unreachable(pid: Int32, endpoint: String, reason: String)
    case handshakeFailed(String)
    case invalidRecord(String)

    var title: String {
        switch self {
        case let .healthy(pid, _):
            "Supervisor Running (PID \(pid))"
        case .notRunning:
            "Supervisor Not Running"
        case let .staleRecord(pid):
            "Supervisor Record Is Stale (PID \(pid))"
        case let .unreachable(pid, _, _):
            "Supervisor Unreachable (PID \(pid))"
        case .handshakeFailed:
            "Supervisor Handshake Failed"
        case .invalidRecord:
            "Supervisor Record Is Invalid"
        }
    }

    var detail: String {
        switch self {
        case let .healthy(_, protocolVersion):
            "Protocol v\(protocolVersion)"
        case .notRunning:
            "No runtime record found at expected path."
        case .staleRecord:
            "Runtime record exists, but the process is not alive."
        case let .unreachable(_, endpoint, reason):
            "Runtime record exists, but socket \(endpoint) is unreachable: \(reason)"
        case let .handshakeFailed(message):
            message
        case let .invalidRecord(message):
            message
        }
    }
}

actor CodexSupervisorHealthChecker {
    private struct RuntimeRecord: Decodable {
        let pid: Int32
        let protocolVersion: Int
        let controlEndpoint: String
        let instanceToken: String
    }

    private struct HelloRequest: Encodable {
        let type = "hello"
        let minProtocolVersion: Int
        let expectedInstanceToken: String?
    }

    private struct ResponseEnvelope: Decodable {
        let type: String
    }

    private struct HelloResponse: Decodable {
        let type: String
        let pid: Int32
        let protocolVersion: Int
        let instanceToken: String
    }

    private struct ErrorResponse: Decodable {
        let type: String
        let message: String
    }

    private enum HandshakeError: LocalizedError {
        case invalidSocketPath(String)
        case unreachable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidSocketPath(path):
                "Socket path is too long for unix domain socket: \(path)"
            case let .unreachable(message):
                message
            case let .failed(message):
                message
            }
        }
    }

    private let runtimeRecordPath: String
    private let fileManager: FileManager

    init(
        runtimeRecordPath: String = "$HOME/Library/Application Support/TicketParty/runtime/supervisor.json",
        fileManager: FileManager = .default
    ) {
        self.runtimeRecordPath = runtimeRecordPath
        self.fileManager = fileManager
    }

    func check() -> CodexSupervisorHealthStatus {
        let resolvedPath = Self.expandPath(runtimeRecordPath)
        guard fileManager.fileExists(atPath: resolvedPath) else {
            return .notRunning
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
            let record = try JSONDecoder().decode(RuntimeRecord.self, from: data)
            guard record.pid > 0 else {
                return .invalidRecord("PID in runtime record must be greater than zero.")
            }
            guard record.controlEndpoint.isEmpty == false else {
                return .invalidRecord("Runtime record is missing control endpoint.")
            }
            guard record.instanceToken.isEmpty == false else {
                return .invalidRecord("Runtime record is missing instance token.")
            }

            let processIsAlive = Self.processExists(pid: record.pid)
            do {
                let hello = try performHelloHandshakeStrictThenRelaxed(
                    socketPath: record.controlEndpoint,
                    expectedInstanceToken: record.instanceToken,
                    minimumProtocolVersion: max(record.protocolVersion, 1)
                )
                return .healthy(pid: hello.pid, protocolVersion: hello.protocolVersion)
            } catch let error as HandshakeError {
                switch error {
                case let .unreachable(message):
                    if processIsAlive {
                        return .unreachable(pid: record.pid, endpoint: record.controlEndpoint, reason: message)
                    }
                    return .staleRecord(pid: record.pid)
                case let .invalidSocketPath(path):
                    return .invalidRecord("Socket path in runtime record is invalid: \(path)")
                case let .failed(message):
                    return .handshakeFailed(message)
                }
            } catch {
                return .handshakeFailed(error.localizedDescription)
            }
        } catch {
            return .invalidRecord(error.localizedDescription)
        }
    }

    private func performHelloHandshakeStrictThenRelaxed(
        socketPath: String,
        expectedInstanceToken: String,
        minimumProtocolVersion: Int
    ) throws -> HelloResponse {
        do {
            return try performHelloHandshake(
                socketPath: socketPath,
                expectedInstanceToken: expectedInstanceToken,
                minimumProtocolVersion: minimumProtocolVersion
            )
        } catch let error as HandshakeError {
            switch error {
            case .failed:
                return try performHelloHandshake(
                    socketPath: socketPath,
                    expectedInstanceToken: nil,
                    minimumProtocolVersion: 1
                )
            case .unreachable, .invalidSocketPath:
                throw error
            }
        }
    }

    private static func expandPath(_ path: String) -> String {
        let expandedTilde = (path as NSString).expandingTildeInPath
        let homeDirectory = NSHomeDirectory()
        let expandedEnv = expandedTilde
            .replacingOccurrences(of: "${HOME}", with: homeDirectory)
            .replacingOccurrences(of: "$HOME", with: homeDirectory)
        return URL(fileURLWithPath: expandedEnv).standardizedFileURL.path
    }

    private static func processExists(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func performHelloHandshake(
        socketPath: String,
        expectedInstanceToken: String?,
        minimumProtocolVersion: Int
    ) throws -> HelloResponse {
        let normalizedSocketPath = Self.expandPath(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HandshakeError.failed("Failed to open socket: \(String(cString: strerror(errno))).")
        }

        defer { Darwin.close(fd) }

        setNoSigPipe(fd: fd)
        setTimeout(fd: fd, option: SO_RCVTIMEO, seconds: 2)
        setTimeout(fd: fd, option: SO_SNDTIMEO, seconds: 2)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let socketPathBytes = normalizedSocketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPathBytes.count <= maxPathLength else {
            throw HandshakeError.invalidSocketPath(normalizedSocketPath)
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
            throw HandshakeError.unreachable(String(cString: strerror(errno)))
        }

        let request = HelloRequest(
            minProtocolVersion: minimumProtocolVersion,
            expectedInstanceToken: expectedInstanceToken
        )

        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        guard writeAll(payload, to: fd) else {
            throw HandshakeError.failed("Failed to write handshake request.")
        }

        guard let responseLine = readLine(from: fd), let responseData = responseLine.data(using: .utf8) else {
            throw HandshakeError.failed("Failed to read handshake response.")
        }

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(ResponseEnvelope.self, from: responseData)
        switch envelope.type {
        case "hello.ok":
            return try decoder.decode(HelloResponse.self, from: responseData)
        case "error":
            let errorResponse = try decoder.decode(ErrorResponse.self, from: responseData)
            throw HandshakeError.failed("Supervisor rejected handshake: \(errorResponse.message)")
        default:
            throw HandshakeError.failed("Unexpected handshake response type: \(envelope.type)")
        }
    }

    private func readLine(from fd: Int32, maxBytes: Int = 16_384) -> String? {
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
