import Foundation
@preconcurrency import AVFoundation

public final class TaskStore {
    public enum StoreError: Error, Equatable {
        case unsupportedAudioFormat(String)
        case unsupportedMediaFormat(String)
        case mediaHasNoAudioTrack(String)
        case audioExtractionFailed(String)
        case taskNotFound(UUID)
    }

    public static let supportedExtensions = MediaFileType.supportedExtensionSet

    public let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public var tasksFileURL: URL {
        rootURL.appendingPathComponent("tasks.json")
    }

    public var tasksRootURL: URL {
        rootURL.appendingPathComponent("tasks", isDirectory: true)
    }

    public func bootstrap() throws {
        try fileManager.createDirectory(at: tasksRootURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: tasksFileURL.path) {
            try save([])
        }
    }

    public func load() throws -> [TranscriptionTask] {
        try bootstrap()
        let data = try Data(contentsOf: tasksFileURL)
        return try decoder.decode([TranscriptionTask].self, from: data)
    }

    @discardableResult
    public func repairLocalAudioDurations(tolerance: TimeInterval = 1.0) throws -> [TranscriptionTask] {
        var tasks = try load()
        var didChange = false
        for index in tasks.indices {
            let audioURL = URL(fileURLWithPath: tasks[index].localAudioPath)
            let duration = Self.audioDurationSeconds(for: audioURL)
            guard duration > 0, abs(duration - tasks[index].durationSec) > tolerance else {
                continue
            }
            tasks[index].durationSec = duration
            didChange = true
        }
        if didChange {
            try save(tasks)
        }
        return tasks
    }

    public func save(_ tasks: [TranscriptionTask]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try encoder.encode(tasks)
        try data.write(to: tasksFileURL, options: .atomic)
    }

    public func createTask(fromAudioURL audioURL: URL, filename: String? = nil) throws -> TranscriptionTask {
        let ext = audioURL.pathExtension.lowercased()
        guard AudioFileType.supportedExtensionSet.contains(ext) else {
            throw StoreError.unsupportedAudioFormat(ext)
        }

        try bootstrap()

        let taskId = UUID()
        let taskDirectory = taskDirectoryURL(for: taskId)
        try fileManager.createDirectory(at: taskDirectory, withIntermediateDirectories: true)

        let localAudioURL = taskDirectory.appendingPathComponent("source.\(ext)")
        if fileManager.fileExists(atPath: localAudioURL.path) {
            try fileManager.removeItem(at: localAudioURL)
        }
        try fileManager.copyItem(at: audioURL, to: localAudioURL)

        let attributes = try fileManager.attributesOfItem(atPath: localAudioURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let duration = Self.audioDurationSeconds(for: localAudioURL)

        let task = TranscriptionTask(
            id: taskId,
            filename: filename ?? audioURL.lastPathComponent,
            localAudioPath: localAudioURL.path,
            durationSec: duration,
            fileSizeBytes: size,
            mediaKind: .audio
        )

        var tasks = try load()
        tasks.insert(task, at: 0)
        try save(tasks)
        return task
    }

    public func createTask(fromMediaURL mediaURL: URL) async throws -> TranscriptionTask {
        let ext = mediaURL.pathExtension.lowercased()
        guard MediaFileType.supportedExtensionSet.contains(ext) else {
            throw StoreError.unsupportedMediaFormat(ext)
        }

        if MediaFileType.isAudio(mediaURL) {
            return try createTask(fromAudioURL: mediaURL)
        }

        guard MediaFileType.isVideo(mediaURL) else {
            throw StoreError.unsupportedMediaFormat(ext)
        }

        try bootstrap()

        let taskId = UUID()
        let taskDirectory = taskDirectoryURL(for: taskId)
        try fileManager.createDirectory(at: taskDirectory, withIntermediateDirectories: true)

        do {
            let localAudioURL = taskDirectory.appendingPathComponent("source.m4a")
            try await MediaAudioExtractor.extractAudio(from: mediaURL, to: localAudioURL)

            let attributes = try fileManager.attributesOfItem(atPath: localAudioURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let duration = Self.audioDurationSeconds(for: localAudioURL)

            let task = TranscriptionTask(
                id: taskId,
                filename: mediaURL.lastPathComponent,
                localAudioPath: localAudioURL.path,
                durationSec: duration,
                fileSizeBytes: size,
                mediaKind: .video
            )

            var tasks = try load()
            tasks.insert(task, at: 0)
            try save(tasks)
            return task
        } catch {
            if fileManager.fileExists(atPath: taskDirectory.path) {
                try? fileManager.removeItem(at: taskDirectory)
            }
            throw error
        }
    }

    public func update(_ task: TranscriptionTask) throws {
        var tasks = try load()
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            throw StoreError.taskNotFound(task.id)
        }
        tasks[index] = task
        try save(tasks)
    }

    public func renameTask(id: UUID, filename: String) throws {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        var tasks = try load()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw StoreError.taskNotFound(id)
        }
        tasks[index].filename = trimmed
        try save(tasks)
    }

    @discardableResult
    public func pauseTasks(ids: Set<UUID>) throws -> [TranscriptionTask] {
        try stopTasks(ids: ids)
    }

    @discardableResult
    public func stopTasks(ids: Set<UUID>) throws -> [TranscriptionTask] {
        guard !ids.isEmpty else {
            return []
        }

        var tasks = try load()
        var changed: [TranscriptionTask] = []
        for index in tasks.indices where ids.contains(tasks[index].id) {
            guard tasks[index].status == .pending || tasks[index].status == .running else {
                continue
            }
            tasks[index].status = .paused
            tasks[index].startedAt = nil
            tasks[index].failedAt = nil
            tasks[index].errorLogPath = nil
            tasks[index].progressFraction = nil
            tasks[index].progressStage = nil
            changed.append(tasks[index])
        }

        if !changed.isEmpty {
            try save(tasks)
        }
        return changed
    }

    @discardableResult
    public func resumeTasks(ids: Set<UUID>) throws -> [TranscriptionTask] {
        try startTasks(ids: ids)
    }

    @discardableResult
    public func startTasks(ids: Set<UUID>) throws -> [TranscriptionTask] {
        guard !ids.isEmpty else {
            return []
        }

        var tasks = try load()
        var changed: [TranscriptionTask] = []
        for index in tasks.indices where ids.contains(tasks[index].id) {
            guard tasks[index].status == .pending
                    || tasks[index].status == .paused
                    || tasks[index].status == .failed else {
                continue
            }
            tasks[index].status = .pending
            tasks[index].startedAt = nil
            tasks[index].completedAt = nil
            tasks[index].failedAt = nil
            tasks[index].transcriptPath = nil
            tasks[index].errorLogPath = nil
            tasks[index].progressFraction = nil
            tasks[index].progressStage = nil
            removeGeneratedOutputs(for: tasks[index].id)
            changed.append(tasks[index])
        }

        if !changed.isEmpty {
            try save(tasks)
        }
        return changed
    }

    @discardableResult
    public func recoverInterruptedTasks() throws -> [TranscriptionTask] {
        var tasks = try load()
        var recovered: [TranscriptionTask] = []

        for index in tasks.indices where tasks[index].status == .running {
            tasks[index].status = .pending
            tasks[index].startedAt = nil
            tasks[index].failedAt = nil
            tasks[index].errorLogPath = nil
            tasks[index].transcriptPath = nil
            tasks[index].progressFraction = nil
            tasks[index].progressStage = nil
            recovered.append(tasks[index])
        }

        if !recovered.isEmpty {
            try save(tasks)
        }

        return recovered
    }

    @discardableResult
    public func repairInvalidCompletedTasks() throws -> [TranscriptionTask] {
        var tasks = try load()
        var repaired: [TranscriptionTask] = []

        for index in tasks.indices where tasks[index].status == .done {
            guard let reason = invalidCompletedTranscriptReason(for: tasks[index]) else {
                continue
            }

            tasks[index].status = .failed
            tasks[index].failedAt = Date()
            tasks[index].transcriptPath = nil
            tasks[index].progressFraction = nil
            tasks[index].progressStage = nil
            tasks[index].errorLogPath = appendTaskErrorLog(
                taskId: tasks[index].id,
                message: reason
            )
            repaired.append(tasks[index])
        }

        if !repaired.isEmpty {
            try save(tasks)
        }

        return repaired
    }

    @discardableResult
    public func repairFailedTasksWithValidTranscript() throws -> [TranscriptionTask] {
        var tasks = try load()
        var repaired: [TranscriptionTask] = []

        for index in tasks.indices where tasks[index].status == .failed {
            let taskDirectoryTranscriptURL = taskDirectoryURL(for: tasks[index].id)
                .appendingPathComponent("transcript.json")
            let transcriptURL = tasks[index].transcriptPath
                .flatMap { path -> URL? in
                    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
                }
                ?? taskDirectoryTranscriptURL

            guard transcriptValidationReason(for: tasks[index], transcriptURL: transcriptURL) == nil else {
                continue
            }

            tasks[index].status = .done
            tasks[index].completedAt = tasks[index].failedAt ?? Date()
            tasks[index].failedAt = nil
            tasks[index].transcriptPath = transcriptURL.path
            tasks[index].errorLogPath = nil
            tasks[index].progressFraction = nil
            tasks[index].progressStage = nil
            repaired.append(tasks[index])
        }

        if !repaired.isEmpty {
            try save(tasks)
        }

        return repaired
    }

    public func deleteTask(id: UUID) throws {
        var tasks = try load()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw StoreError.taskNotFound(id)
        }
        tasks.remove(at: index)
        try save(tasks)

        let taskDirectory = taskDirectoryURL(for: id)
        if fileManager.fileExists(atPath: taskDirectory.path) {
            try fileManager.removeItem(at: taskDirectory)
        }
    }

    public func taskDirectoryURL(for taskId: UUID) -> URL {
        tasksRootURL.appendingPathComponent(taskId.uuidString, isDirectory: true)
    }

    public static func audioDurationSeconds(for url: URL) -> Double {
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return 0
        }
        return player.duration
    }

    private func invalidCompletedTranscriptReason(for task: TranscriptionTask) -> String? {
        guard let transcriptPath = task.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcriptPath.isEmpty else {
            return "completed task has no transcript path"
        }

        return transcriptValidationReason(for: task, transcriptURL: URL(fileURLWithPath: transcriptPath))
    }

    func transcriptValidationReason(for task: TranscriptionTask, transcriptURL: URL) -> String? {
        let normalizedTranscriptURL = transcriptURL.standardizedFileURL
        let normalizedTaskDirectory = taskDirectoryURL(for: task.id).standardizedFileURL
        let taskDirectoryPath = normalizedTaskDirectory.path
        let transcriptPath = normalizedTranscriptURL.path

        guard transcriptPath == taskDirectoryPath || transcriptPath.hasPrefix(taskDirectoryPath + "/") else {
            return "completed task transcript is outside task directory: \(transcriptPath)"
        }

        guard fileManager.fileExists(atPath: transcriptPath) else {
            return "completed task transcript file is missing: \(transcriptPath)"
        }

        let transcript: Transcript
        do {
            transcript = try TranscriptStore.load(from: normalizedTranscriptURL)
        } catch {
            return "completed task transcript is unreadable: \(transcriptPath); \(String(describing: error))"
        }

        guard transcript.taskId == task.id else {
            return "completed task transcript task id mismatch: expected \(task.id.uuidString), got \(transcript.taskId.uuidString)"
        }

        guard transcriptHasUsableText(transcript) else {
            return "completed task transcript is empty: \(transcriptPath)"
        }
        return nil
    }

    private func transcriptHasUsableText(_ transcript: Transcript) -> Bool {
        let hasText = !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSegmentText = transcript.segments.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasText || hasSegmentText
    }

    public func removeGeneratedOutputs(for taskId: UUID) {
        let taskDirectory = taskDirectoryURL(for: taskId)
        for filename in ["transcript.json", "alignment.json", "error.log", "worker-events.jsonl"] {
            let url = taskDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        let audioSegmentsURL = taskDirectory.appendingPathComponent("audio-segments", isDirectory: true)
        if fileManager.fileExists(atPath: audioSegmentsURL.path) {
            try? fileManager.removeItem(at: audioSegmentsURL)
        }
    }

    private func appendTaskErrorLog(taskId: UUID, message: String) -> String {
        let taskDirectory = taskDirectoryURL(for: taskId)
        let errorLogURL = taskDirectory.appendingPathComponent("error.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(timestamp)] \(message)\n"

        try? fileManager.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: errorLogURL.path),
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
