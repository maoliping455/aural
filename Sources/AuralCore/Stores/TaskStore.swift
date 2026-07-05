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
            changed.append(tasks[index])
        }

        if !changed.isEmpty {
            try save(tasks)
        }
        return changed
    }

    @discardableResult
    public func resumeTasks(ids: Set<UUID>) throws -> [TranscriptionTask] {
        guard !ids.isEmpty else {
            return []
        }

        var tasks = try load()
        var changed: [TranscriptionTask] = []
        for index in tasks.indices where ids.contains(tasks[index].id) {
            guard tasks[index].status == .paused else {
                continue
            }
            tasks[index].status = .pending
            tasks[index].startedAt = nil
            tasks[index].completedAt = nil
            tasks[index].failedAt = nil
            tasks[index].transcriptPath = nil
            tasks[index].errorLogPath = nil
            tasks[index].progressFraction = nil
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
            recovered.append(tasks[index])
        }

        if !recovered.isEmpty {
            try save(tasks)
        }

        return recovered
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

}
