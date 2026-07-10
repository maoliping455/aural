import Darwin
import Foundation

public final class AuralChildProcessRegistry: @unchecked Sendable {
    public static let shared = AuralChildProcessRegistry()

    private let lock = NSLock()
    private var processes: [pid_t: Process] = [:]

    private init() {}

    public func register(_ process: Process) {
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
    }

    public func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: process.processIdentifier)
        lock.unlock()
    }

    public func terminate(_ process: Process) {
        terminateProcessTree(rootPID: process.processIdentifier)
        if process.isRunning {
            process.waitUntilExit()
        }
        unregister(process)
    }

    public func terminateAll() {
        let snapshot: [Process]
        lock.lock()
        snapshot = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        for process in snapshot {
            terminateProcessTree(rootPID: process.processIdentifier)
        }
        for process in snapshot where process.isRunning {
            process.waitUntilExit()
        }
    }

    public func terminateStaleAuralHelpers() {
        for pid in staleAuralHelperProcessIDs() {
            terminateProcessTree(rootPID: pid)
        }
    }
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

private func staleAuralHelperProcessIDs() -> [pid_t] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["axo", "pid=,command="]

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

    let currentPID = getpid()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output
        .split(whereSeparator: \.isNewline)
        .compactMap { line -> pid_t? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }
            guard let pid = pid_t(trimmed[..<separator]), pid != currentPID else {
                return nil
            }
            let command = String(trimmed[separator...])
            guard command.contains("/Aural.app/Contents/Resources/AuralASRWorker/") else {
                return nil
            }
            guard command.contains("worker_qwen") || command.contains("model_resource_prepare.py") else {
                return nil
            }
            return pid
        }
}
