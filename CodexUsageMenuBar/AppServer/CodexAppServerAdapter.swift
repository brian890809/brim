import Darwin
import Foundation

protocol RateLimitProviding: Sendable {
    func fetchUsage() async throws -> CodexUsageSnapshot
}
actor CodexAppServerAdapter: RateLimitProviding {
    private let resolver: CodexExecutableResolver
    private let timeout: TimeInterval

    init(resolver: CodexExecutableResolver, timeout: TimeInterval = 15) {
        self.resolver = resolver
        self.timeout = timeout
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        let executableURL = try resolver.resolve()
        let response = try AppServerSession(
            executableURL: executableURL,
            timeout: timeout
        ).readRateLimits()
        return CodexUsageSnapshot(response: response)
    }
}

enum CodexAppServerError: LocalizedError, Equatable {
    case executableNotFound
    case launchFailed
    case timedOut
    case connectionClosed
    case malformedResponse
    case responseError(code: Int?)
    case processExited(status: Int32)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex could not be found. Install or open Codex, then refresh."
        case .launchFailed:
            return "Codex could not be started. Open Codex once, then refresh."
        case .timedOut:
            return "Codex took too long to report usage. Try refreshing again."
        case .connectionClosed:
            return "Codex closed the usage connection before replying."
        case .malformedResponse:
            return "Codex returned usage data this version cannot read."
        case let .responseError(code):
            if let code {
                return "Codex could not report usage (error \(code)). Confirm you are signed in."
            }
            return "Codex could not report usage. Confirm you are signed in."
        case let .processExited(status):
            return "Codex stopped before usage was read (status \(status))."
        }
    }
}

struct AccountRateLimitsResponse: Decodable, Sendable {
    let rateLimits: RateLimitSnapshotPayload
    let rateLimitsByLimitId: [String: RateLimitSnapshotPayload]?

    var preferredCodexRateLimit: RateLimitSnapshotPayload {
        if let codex = rateLimitsByLimitId?["codex"] {
            return codex
        }

        if let codex = rateLimitsByLimitId?.values.first(where: { $0.limitId == "codex" }) {
            return codex
        }

        return rateLimits
    }
}

struct RateLimitSnapshotPayload: Decodable, Sendable {
    let limitId: String?
    let primary: RateLimitWindowPayload?
    let secondary: RateLimitWindowPayload?
}

struct RateLimitWindowPayload: Decodable, Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

private final class AppServerSession {
    private static let initializeID = 1
    private static let rateLimitsID = 2
    private static let maximumLineBytes = 1_048_576

    private let executableURL: URL
    private let timeout: TimeInterval
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var inputIsClosed = false
    private var lineBuffer = JSONLineBuffer(maximumBytes: AppServerSession.maximumLineBytes)

    init(executableURL: URL, timeout: TimeInterval) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func readRateLimits() throws -> AccountRateLimitsResponse {
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe

        // App-server diagnostics can be noisy and are not part of the protocol. Discarding
        // them also guarantees this app never surfaces accidental sensitive diagnostic data.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed
        }

        defer {
            stopProcessIfNeeded()
        }

        let deadline = DispatchTime.now() + timeout

        try send([
            "id": Self.initializeID,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-usage-menubar",
                    "title": "Codex Usage Menubar",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "experimentalApi": false,
                    "requestAttestation": false,
                ],
            ],
        ])
        _ = try readResult(for: Self.initializeID, deadline: deadline)

        try send(["method": "initialized"])
        try send([
            "id": Self.rateLimitsID,
            "method": "account/rateLimits/read",
        ])

        let result = try readResult(for: Self.rateLimitsID, deadline: deadline)
        let resultData: Data
        do {
            resultData = try JSONSerialization.data(withJSONObject: result)
        } catch {
            throw CodexAppServerError.malformedResponse
        }

        let response: AccountRateLimitsResponse
        do {
            response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: resultData)
        } catch {
            throw CodexAppServerError.malformedResponse
        }

        closeInput()
        try waitForCleanExit()
        return response
    }

    private func send(_ object: [String: Any]) throws {
        let data: Data
        do {
            var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            encoded.append(0x0A)
            data = encoded
        } catch {
            throw CodexAppServerError.malformedResponse
        }

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.connectionClosed
        }
    }

    private func readResult(for expectedID: Int, deadline: DispatchTime) throws -> Any {
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }

            if let line = try lineBuffer.popLine() {
                let message: [String: Any]
                do {
                    guard let decoded = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw CodexAppServerError.malformedResponse
                    }
                    message = decoded
                } catch let error as CodexAppServerError {
                    throw error
                } catch {
                    throw CodexAppServerError.malformedResponse
                }

                guard (message["id"] as? NSNumber)?.intValue == expectedID else {
                    continue
                }

                if let error = message["error"] as? [String: Any] {
                    throw CodexAppServerError.responseError(
                        code: (error["code"] as? NSNumber)?.intValue
                    )
                }

                guard let result = message["result"] else {
                    throw CodexAppServerError.malformedResponse
                }
                return result
            }

            try readMore(deadline: deadline)
        }
    }

    private func readMore(deadline: DispatchTime) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = deadline.uptimeNanoseconds
        guard now < end else {
            throw CodexAppServerError.timedOut
        }

        let remainingMilliseconds = max(1, Int((end - now) / 1_000_000))
        var descriptor = pollfd(
            fd: outputPipe.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let pollResult = poll(&descriptor, 1, Int32(min(remainingMilliseconds, 100)))

        if pollResult == 0 {
            return
        }

        if pollResult < 0 {
            if errno == EINTR { return }
            throw CodexAppServerError.connectionClosed
        }

        if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
            throw CodexAppServerError.connectionClosed
        }

        var bytes = [UInt8](repeating: 0, count: 16_384)
        let byteCount = Darwin.read(descriptor.fd, &bytes, bytes.count)
        if byteCount == 0 {
            if process.isRunning {
                throw CodexAppServerError.connectionClosed
            }
            throw CodexAppServerError.processExited(status: process.terminationStatus)
        }

        if byteCount < 0 {
            if errno == EINTR { return }
            throw CodexAppServerError.connectionClosed
        }

        try lineBuffer.append(bytes.prefix(byteCount))
    }

    private func closeInput() {
        guard !inputIsClosed else { return }
        inputIsClosed = true
        try? inputPipe.fileHandleForWriting.close()
    }

    private func waitForCleanExit() throws {
        let exitDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < exitDeadline {
            usleep(10_000)
        }

        guard !process.isRunning else {
            return
        }

        if process.terminationStatus != 0 {
            throw CodexAppServerError.processExited(status: process.terminationStatus)
        }
    }

    private func stopProcessIfNeeded() {
        closeInput()
        guard process.isRunning else { return }

        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < terminationDeadline {
            usleep(10_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

struct JSONLineBuffer {
    private var data = Data()
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append<S: Sequence>(_ bytes: S) throws where S.Element == UInt8 {
        data.append(contentsOf: bytes)
        if data.count > maximumBytes && !data.contains(0x0A) {
            throw CodexAppServerError.malformedResponse
        }
    }

    mutating func popLine() throws -> Data? {
        guard let newlineIndex = data.firstIndex(of: 0x0A) else {
            return nil
        }

        var line = Data(data[..<newlineIndex])
        data.removeSubrange(...newlineIndex)

        if line.last == 0x0D {
            line.removeLast()
        }

        guard !line.isEmpty, line.count <= maximumBytes else {
            throw CodexAppServerError.malformedResponse
        }
        return line
    }
}
