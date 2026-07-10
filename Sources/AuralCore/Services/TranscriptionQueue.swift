import Foundation

public final class TranscriptionQueue {
    private let store: TaskStore
    private let workerClient: ASRWorkerClient

    public init(store: TaskStore, workerClient: ASRWorkerClient) {
        self.store = store
        self.workerClient = workerClient
    }

    @discardableResult
    public func runNextPendingTask() throws -> TranscriptionTask? {
        let tasks = try store.load()
        let pendingTasks = tasks.enumerated().filter { $0.element.status == .pending }
        guard var task = pendingTasks.min(by: { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt < rhs.element.createdAt
            }
            return lhs.offset > rhs.offset
        })?.element else {
            return nil
        }

        store.removeGeneratedOutputs(for: task.id)

        task.status = .running
        task.startedAt = Date()
        task.progressFraction = 0
        task.progressStage = nil
        try store.update(task)

        let outputDir = store.taskDirectoryURL(for: task.id)
        do {
            let events = try workerClient.transcribe(
                task: task,
                outputDir: outputDir,
                shouldCancel: { [store] in
                    shouldCancelTask(task.id, store: store)
                },
                onEvent: { [store] event in
                    guard event.type == WorkerEventType.progress else {
                        return
                    }
                    updateProgress(for: task.id, event: event, store: store)
                }
            )
            if let failed = events.first(where: { $0.type == WorkerEventType.failed }) {
                guard var latest = try currentRunningTask(task.id, store: store) else {
                    return currentTaskOrOriginal(task, store: store)
                }
                latest.status = .failed
                latest.failedAt = Date()
                latest.errorLogPath = failed.errorLogPath
                latest.progressFraction = nil
                latest.progressStage = nil
                try store.update(latest)
                return latest
            }

            guard let completed = events.last(where: { $0.type == WorkerEventType.completed }) else {
                throw ASRWorkerClient.ClientError.missingCompletionEvent(task.id)
            }

            guard var latest = try currentRunningTask(task.id, store: store) else {
                return currentTaskOrOriginal(task, store: store)
            }
            do {
                try validateCompletedTranscript(completed, expectedTask: latest, store: store)
            } catch {
                latest.status = .failed
                latest.failedAt = Date()
                latest.transcriptPath = nil
                latest.errorLogPath = ensureFailureLog(outputDir: outputDir, error: error)
                latest.progressFraction = nil
                latest.progressStage = nil
                try store.update(latest)
                return latest
            }
            latest.status = .done
            latest.completedAt = Date()
            latest.transcriptPath = completed.transcriptPath
            latest.durationSec = reconciledDuration(for: latest, workerDuration: completed.durationSec)
            latest.progressFraction = nil
            latest.progressStage = nil
            try store.update(latest)
            return latest
        } catch ASRWorkerClient.ClientError.cancelled {
            return currentTaskOrOriginal(task, store: store)
        } catch {
            if try currentTask(task.id, store: store)?.status == .paused {
                return currentTaskOrOriginal(task, store: store)
            }
            var latest = try currentTask(task.id, store: store) ?? task
            latest.status = .failed
            latest.failedAt = Date()
            latest.errorLogPath = ensureFailureLog(outputDir: outputDir, error: error)
            latest.progressFraction = nil
            latest.progressStage = nil
            try store.update(latest)
            throw error
        }
    }

    @discardableResult
    public func drainPendingTasks() throws -> [TranscriptionTask] {
        var completed: [TranscriptionTask] = []
        while let task = try runNextPendingTask() {
            completed.append(task)
        }
        return completed
    }

    private func ensureFailureLog(outputDir: URL, error: Error) -> String {
        let errorLogURL = outputDir.appendingPathComponent("error.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(timestamp)] \(String(describing: error))\n"
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: errorLogURL.path),
           let handle = try? FileHandle(forWritingTo: errorLogURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: errorLogURL, options: .atomic)
        }
        return errorLogURL.path
    }
}

private enum CompletedTranscriptValidationError: Error, CustomStringConvertible {
    case missingTranscriptPath
    case transcriptFileMissing(String)
    case unreadableTranscript(String, String)
    case emptyTranscript(String)
    case invalidTranscript(String)

    var description: String {
        switch self {
        case .missingTranscriptPath:
            return "completed event produced no transcript path"
        case .transcriptFileMissing(let path):
            return "completed event transcript file is missing: \(path)"
        case .unreadableTranscript(let path, let reason):
            return "completed event transcript is unreadable: \(path); \(reason)"
        case .emptyTranscript(let path):
            return "completed event transcript is empty: \(path)"
        case .invalidTranscript(let reason):
            return reason
        }
    }
}

private func validateCompletedTranscript(_ event: WorkerEvent, expectedTask: TranscriptionTask, store: TaskStore) throws {
    guard let transcriptPath = event.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
          !transcriptPath.isEmpty else {
        throw CompletedTranscriptValidationError.missingTranscriptPath
    }

    let transcriptURL = URL(fileURLWithPath: transcriptPath)
    guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
        throw CompletedTranscriptValidationError.transcriptFileMissing(transcriptURL.path)
    }

    if let reason = store.transcriptValidationReason(for: expectedTask, transcriptURL: transcriptURL) {
        throw CompletedTranscriptValidationError.invalidTranscript("completed event transcript is invalid: \(reason)")
    }
}

private func reconciledDuration(for task: TranscriptionTask, workerDuration: Double?) -> Double {
    let localDuration = TaskStore.audioDurationSeconds(for: URL(fileURLWithPath: task.localAudioPath))
    guard let workerDuration, workerDuration > 0 else {
        return localDuration > 0 ? localDuration : task.durationSec
    }
    guard localDuration > 0 else {
        return workerDuration
    }

    let tolerance = max(2.0, localDuration * 0.2)
    if abs(localDuration - workerDuration) > tolerance {
        return localDuration
    }
    return workerDuration
}

private func shouldCancelTask(_ taskId: UUID, store: TaskStore) -> Bool {
    guard let tasks = try? store.load() else {
        return false
    }
    guard let task = tasks.first(where: { $0.id == taskId }) else {
        return true
    }
    return task.status != .running
}

private func currentTask(_ taskId: UUID, store: TaskStore) throws -> TranscriptionTask? {
    let tasks = try store.load()
    return tasks.first(where: { $0.id == taskId })
}

private func currentRunningTask(_ taskId: UUID, store: TaskStore) throws -> TranscriptionTask? {
    guard let task = try currentTask(taskId, store: store), task.status == .running else {
        return nil
    }
    return task
}

private func currentTaskOrOriginal(_ original: TranscriptionTask, store: TaskStore) -> TranscriptionTask {
    (try? currentTask(original.id, store: store)) ?? original
}

private func updateProgress(for taskId: UUID, event: WorkerEvent, store: TaskStore) {
    guard
        let completed = event.completedSegments,
        let total = event.totalSegments,
        total > 0
    else {
        return
    }

    let rawFraction = min(max(Double(completed) / Double(total), 0), 0.99)
    let fraction = max(rawFraction, progressFloor(for: event.stage))
    do {
        var tasks = try store.load()
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            return
        }
        guard tasks[index].status == .running else {
            return
        }
        let previous = tasks[index].progressFraction ?? 0
        tasks[index].progressFraction = max(previous, fraction)
        tasks[index].progressStage = event.stage
        try store.save(tasks)
    } catch {
        // Progress is best-effort; final task state still comes from terminal worker events.
    }
}

private func progressFloor(for stage: String?) -> Double {
    switch stage {
    case "preparing":
        return 0.01
    case "normalizing":
        return 0.02
    case "reading_audio":
        return 0.03
    case "segmenting":
        return 0.04
    case "loading":
        return 0.05
    case "transcribing":
        return 0.06
    case "aligning":
        return 0.60
    default:
        return 0
    }
}
