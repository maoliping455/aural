import Darwin
import Foundation

public final class ASRWorkerClient {
    public enum ClientError: Error, Equatable {
        case invalidUTF8Output
        case workerExited(Int32, String)
        case workerTimedOut(TimeInterval)
        case missingCompletionEvent(UUID)
        case cancelled(UUID)
    }

    public static let defaultTimeoutSeconds: TimeInterval = 6 * 60 * 60

    public let workerURL: URL
    public let pythonExecutableURL: URL
    public let timeoutSeconds: TimeInterval?

    public init(
        workerURL: URL,
        pythonExecutableURL: URL = RuntimePaths.defaultPythonExecutableURL(),
        timeoutSeconds: TimeInterval? = ASRWorkerClient.defaultTimeoutSeconds
    ) {
        self.workerURL = workerURL
        self.pythonExecutableURL = pythonExecutableURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func transcribe(
        task: TranscriptionTask,
        outputDir: URL,
        shouldCancel: (() -> Bool)? = nil,
        onEvent: ((WorkerEvent) -> Void)? = nil
    ) throws -> [WorkerEvent] {
        let request = WorkerRequest(
            taskId: task.id,
            audioPath: task.localAudioPath,
            outputDir: outputDir.path,
            durationSec: task.durationSec
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let requestData = try encoder.encode(request) + Data([0x0A])

        let process = Process()
        process.executableURL = pythonExecutableURL
        process.arguments = workerArguments()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let outputReader = WorkerEventReader(
            fileHandle: stdout.fileHandleForReading,
            decoder: decoder,
            onEvent: onEvent
        )
        let errorReader = PipeReader(fileHandle: stderr.fileHandleForReading)
        outputReader.start()
        errorReader.start()

        stdin.fileHandleForWriting.write(requestData)
        try stdin.fileHandleForWriting.close()

        switch waitForExit(process, timeoutSeconds: timeoutSeconds, shouldCancel: shouldCancel) {
        case .exited:
            break
        case .cancelled:
            terminateProcessTree(rootPID: process.processIdentifier)
            process.waitUntilExit()
            _ = outputReader.wait()
            _ = errorReader.wait()
            throw ClientError.cancelled(task.id)
        case .timedOut:
            terminateProcessTree(rootPID: process.processIdentifier)
            process.waitUntilExit()
            _ = outputReader.wait()
            let errorData = errorReader.wait()
            let stderrText = String(data: errorData, encoding: .utf8) ?? ""
            if !stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try appendWorkerLog(stderrText, outputDir: outputDir)
            }
            let timeout = timeoutSeconds ?? 0
            try appendWorkerLog("worker timed out after \(String(format: "%.3f", timeout)) seconds", outputDir: outputDir)
            throw ClientError.workerTimedOut(timeout)
        }

        let outputResult = outputReader.wait()
        let errorData = errorReader.wait()

        let stderrText = String(data: errorData, encoding: .utf8) ?? ""
        if !stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try appendWorkerLog(stderrText, outputDir: outputDir)
        }
        guard process.terminationStatus == 0 else {
            try appendWorkerLog("worker exited with status \(process.terminationStatus)", outputDir: outputDir)
            throw ClientError.workerExited(process.terminationStatus, stderrText)
        }

        if let error = outputResult.error {
            throw error
        }

        let events = outputResult.events

        if !events.contains(where: { $0.type == WorkerEventType.completed || $0.type == WorkerEventType.failed }) {
            throw ClientError.missingCompletionEvent(task.id)
        }

        return events
    }

    private func workerArguments() -> [String] {
        if pythonExecutableURL.path == "/usr/bin/env" {
            return ["python3", workerURL.path]
        }
        return [workerURL.path]
    }

    private enum WaitOutcome {
        case exited
        case timedOut
        case cancelled
    }

    private func waitForExit(
        _ process: Process,
        timeoutSeconds: TimeInterval?,
        shouldCancel: (() -> Bool)?
    ) -> WaitOutcome {
        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
        while process.isRunning {
            if shouldCancel?() == true {
                return .cancelled
            }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    return .timedOut
                }
                Thread.sleep(forTimeInterval: min(0.1, remaining))
            } else {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return .exited
    }

    private func terminateProcessTree(rootPID: pid_t) {
        let descendants = descendantProcessIDs(of: rootPID)
        for pid in descendants.reversed() {
            Darwin.kill(pid, SIGTERM)
        }
        Darwin.kill(rootPID, SIGTERM)

        Thread.sleep(forTimeInterval: 0.4)

        let remaining = descendantProcessIDs(of: rootPID)
        for pid in remaining.reversed() {
            Darwin.kill(pid, SIGKILL)
        }
        Darwin.kill(rootPID, SIGKILL)
    }

    private func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var stack = [rootPID]
        var seen = Set<pid_t>()

        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else {
                continue
            }
            let children = directChildProcessIDs(of: pid)
            result.append(contentsOf: children)
            stack.append(contentsOf: children)
        }

        return result
    }

    private func directChildProcessIDs(of pid: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func appendWorkerLog(_ text: String, outputDir: URL) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let logURL = outputDir.appendingPathComponent("error.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(text.trimmingCharacters(in: .newlines))\n"
        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
            try handle.close()
        } else {
            try Data(entry.utf8).write(to: logURL, options: .atomic)
        }
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}

private final class WorkerEventReader: @unchecked Sendable {
    struct Result {
        let events: [WorkerEvent]
        let error: Error?
    }

    private let fileHandle: FileHandle
    private let decoder: JSONDecoder
    private let onEvent: ((WorkerEvent) -> Void)?
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var events: [WorkerEvent] = []
    private var error: Error?

    init(fileHandle: FileHandle, decoder: JSONDecoder, onEvent: ((WorkerEvent) -> Void)?) {
        self.fileHandle = fileHandle
        self.decoder = decoder
        self.onEvent = onEvent
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = self.fileHandle.availableData
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
                self.consumeCompleteLines(from: &buffer)
            }

            if !buffer.isEmpty {
                self.consumeLine(buffer)
            }
            self.group.leave()
        }
    }

    func wait() -> Result {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return Result(events: events, error: error)
    }

    private func consumeCompleteLines(from buffer: inout Data) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            consumeLine(Data(line))
            buffer.removeSubrange(...newline)
        }
    }

    private func consumeLine(_ line: Data) {
        guard !line.isEmpty else {
            return
        }

        do {
            let event = try decoder.decode(WorkerEvent.self, from: line)
            lock.lock()
            events.append(event)
            lock.unlock()
            onEvent?(event)
        } catch {
            lock.lock()
            if self.error == nil {
                self.error = error
            }
            lock.unlock()
        }
    }
}

private final class PipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let readData = self.fileHandle.readDataToEndOfFile()
            self.lock.lock()
            self.data = readData
            self.lock.unlock()
            self.group.leave()
        }
    }

    func wait() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
