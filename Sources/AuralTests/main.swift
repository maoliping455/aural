import AuralCore
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    fputs("aural-test failed: \(message)\n", stderr)
    exit(1)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fail(message)
    }
}

func requireEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fail("\(message): expected \(expected), got \(actual)")
    }
}

func requireUnwrapped<T>(_ value: T?, _ message: String) -> T {
    guard let value else {
        fail(message)
    }
    return value
}

func requireJSONNumber(_ value: JSONValue?, _ expected: Double, _ message: String) {
    guard case .number(let actual) = value, abs(actual - expected) < 0.0001 else {
        fail(message)
    }
}

func requireJSONString(_ value: JSONValue?, _ expected: String, _ message: String) {
    guard case .string(let actual) = value, actual == expected else {
        fail(message)
    }
}

func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuralTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func setEnvironmentVariable(_ key: String, _ value: String?) {
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
}

func withTemporaryEnvironment(_ updates: [String: String?], body: () throws -> Void) throws {
    let original = ProcessInfo.processInfo.environment
    for (key, value) in updates {
        setEnvironmentVariable(key, value)
    }
    defer {
        for key in updates.keys {
            setEnvironmentVariable(key, original[key])
        }
    }
    try body()
}

func writeSparseModelSkeleton(
    to url: URL,
    safetensorsBytes: UInt64,
    includeRequiredFiles: Bool = true,
    includeCompletionMarker: Bool = false
) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let supportingFiles = includeRequiredFiles
        ? RuntimePaths.modelRequiredFiles.filter { $0 != "model.safetensors" }
        : ["config.json", "tokenizer_config.json"]
    for filename in supportingFiles {
        try Data("{}".utf8).write(to: url.appendingPathComponent(filename))
    }
    let modelURL = url.appendingPathComponent("model.safetensors")
    FileManager.default.createFile(atPath: modelURL.path, contents: Data())
    let handle = try FileHandle(forWritingTo: modelURL)
    try handle.truncate(atOffset: safetensorsBytes)
    try handle.close()
    if includeCompletionMarker {
        try Data("{}".utf8).write(to: url.appendingPathComponent(RuntimePaths.modelCompletionMarkerFilename))
    }
}

func writeUsableTranscript(to url: URL, taskId: UUID, text: String = "restored transcript") throws {
    let transcript = Transcript(
        taskId: taskId,
        audioDurationSec: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        segments: [
            TranscriptSegment(startSec: 0, endSec: 1, text: text)
        ],
        text: text
    )
    try TranscriptStore.save(transcript, to: url)
}

func writeWorkerScript(named filename: String, in root: URL, body: String) throws -> URL {
    let workerURL = root.appendingPathComponent(filename)
    try Data(body.utf8).write(to: workerURL)
    return workerURL
}

func makeTestWorkerClient(
    workerURL: URL,
    timeoutSeconds: TimeInterval? = ASRWorkerClient.defaultTimeoutSeconds
) -> ASRWorkerClient {
    ASRWorkerClient(
        workerURL: workerURL,
        pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/env"),
        timeoutSeconds: timeoutSeconds,
        environment: ["PYTHONDONTWRITEBYTECODE": "1"]
    )
}

final class ModelResourceEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelResourceEvent] = []

    func append(_ event: ModelResourceEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    var events: [ModelResourceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class QueueRunResultSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<TranscriptionTask?, Error>?

    func store(_ result: Result<TranscriptionTask?, Error>) {
        lock.lock()
        defer { lock.unlock() }
        storage = result
    }

    var result: Result<TranscriptionTask?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class QueueRunHarness: @unchecked Sendable {
    private let queue: TranscriptionQueue
    let sink = QueueRunResultSink()

    init(queue: TranscriptionQueue) {
        self.queue = queue
    }

    func startNextPendingTask() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                sink.store(.success(try queue.runNextPendingTask()))
            } catch {
                sink.store(.failure(error))
            }
        }
    }
}

func waitUntil(
    _ message: String,
    timeoutSeconds: TimeInterval = 5,
    condition: () throws -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if try condition() {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fail(message)
}

func makeTestTask(audioPath: String? = nil) -> TranscriptionTask {
    TranscriptionTask(
        id: UUID(),
        filename: "input.m4a",
        localAudioPath: audioPath ?? "/tmp/aural-test-input.m4a",
        durationSec: 1,
        fileSizeBytes: 1,
        status: .pending,
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

func testMediaFileTypes() {
    require(AudioFileType.isSupported(URL(fileURLWithPath: "/tmp/voice.MP3")), "MP3 should be supported")
    require(AudioFileType.isSupported(URL(fileURLWithPath: "/tmp/voice.FlAc")), "FLAC should be supported")
    require(VideoFileType.isSupported(URL(fileURLWithPath: "/tmp/demo.MOV")), "MOV should be supported")
    require(MediaFileType.isSupported(URL(fileURLWithPath: "/tmp/demo.m4v")), "M4V should be supported")
    require(!MediaFileType.isSupported(URL(fileURLWithPath: "/tmp/notes.txt")), "TXT should not be supported")
    requireEqual(TaskStore.supportedExtensions, MediaFileType.supportedExtensionSet, "TaskStore supported extensions")
}

func testTranscriptExportRenderer() {
    let transcript = Transcript(
        taskId: UUID(),
        audioDurationSec: 5.2,
        createdAt: Date(timeIntervalSince1970: 0),
        segments: [
            TranscriptSegment(startSec: -1, endSec: .nan, text: "  hello\nworld  "),
            TranscriptSegment(startSec: 3.1, endSec: 3.0, text: "  "),
            TranscriptSegment(startSec: 3.1, endSec: .nan, text: " done ")
        ],
        text: "fallback text"
    )

    let plainText = TranscriptExportRenderer.render(transcript, format: .plainText)
    requireEqual(plainText, "hello world\ndone\n", "plain text export")

    let timestampedText = TranscriptExportRenderer.render(transcript, format: .timestampedText)
    requireEqual(
        timestampedText,
        "[00:00 - 00:03] hello world\n[00:03 - 00:05] done\n",
        "timestamped text export"
    )

    let srt = TranscriptExportRenderer.render(transcript, format: .srt)
    requireEqual(
        srt,
        """
        1
        00:00:00,000 --> 00:00:03,100
        hello world

        2
        00:00:03,100 --> 00:00:05,200
        done

        """,
        "SRT export"
    )
}

func testTranscriptExportRendererFallsBackToTopLevelTextWhenSegmentsAreEmpty() {
    let transcript = Transcript(
        taskId: UUID(),
        audioDurationSec: 10,
        createdAt: Date(timeIntervalSince1970: 0),
        segments: [
            TranscriptSegment(startSec: 0, endSec: 2, text: "   ")
        ],
        text: "  fallback\n\ntext  "
    )

    let plainText = TranscriptExportRenderer.render(transcript, format: .plainText)
    requireEqual(plainText, "fallback text\n", "plain text export should fall back to top-level text")

    let timestampedText = TranscriptExportRenderer.render(transcript, format: .timestampedText)
    requireEqual(timestampedText, "", "timestamped export should not invent timings without segment text")

    let srt = TranscriptExportRenderer.render(transcript, format: .srt)
    requireEqual(srt, "", "SRT export should not invent cues without segment text")
}

func testTaskStoreLifecycle() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let originalAudio = root.appendingPathComponent("Original.M4A")
    try Data("not a real audio file, but enough for storage tests".utf8).write(to: originalAudio)

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()

    let task = try store.createTask(fromAudioURL: originalAudio)
    requireEqual(task.filename, "Original.M4A", "created task filename")
    requireEqual(task.mediaKind, .audio, "created task media kind")
    require(task.localAudioPath.hasSuffix("source.m4a"), "local audio copy should normalize extension")
    require(FileManager.default.fileExists(atPath: task.localAudioPath), "local audio copy should exist")
    require(FileManager.default.fileExists(atPath: originalAudio.path), "original audio should remain")

    try store.renameTask(id: task.id, filename: "  Interview clip.m4a  ")
    requireEqual(try store.load().first?.filename, "Interview clip.m4a", "rename should trim whitespace")

    try store.renameTask(id: task.id, filename: "   ")
    requireEqual(try store.load().first?.filename, "Interview clip.m4a", "empty rename should be ignored")

    var failedTask = requireUnwrapped(try store.load().first, "task should exist before restart")
    failedTask.status = .failed
    failedTask.errorLogPath = store.taskDirectoryURL(for: failedTask.id)
        .appendingPathComponent("error.log")
        .path
    failedTask.transcriptPath = store.taskDirectoryURL(for: failedTask.id)
        .appendingPathComponent("transcript.json")
        .path
    failedTask.progressFraction = 0.5
    failedTask.progressStage = "transcribing"
    try Data("old error".utf8).write(to: URL(fileURLWithPath: requireUnwrapped(failedTask.errorLogPath, "error path")))
    try Data("{\"segments\":[]}".utf8)
        .write(to: URL(fileURLWithPath: requireUnwrapped(failedTask.transcriptPath, "transcript path")))
    let staleChunkDirectory = store.taskDirectoryURL(for: failedTask.id)
        .appendingPathComponent("audio-segments/chunks", isDirectory: true)
    try FileManager.default.createDirectory(at: staleChunkDirectory, withIntermediateDirectories: true)
    try Data("stale chunk".utf8)
        .write(to: staleChunkDirectory.appendingPathComponent("chunk-0002.wav"))
    try store.update(failedTask)

    let restarted = try store.startTasks(ids: [task.id])
    requireEqual(restarted.count, 1, "restart should update one task")
    let restartedTask = requireUnwrapped(try store.load().first, "task should exist after restart")
    requireEqual(restartedTask.status, .pending, "restarted task status")
    require(restartedTask.errorLogPath == nil, "restart should clear error log path")
    require(restartedTask.transcriptPath == nil, "restart should clear transcript path")
    require(restartedTask.progressFraction == nil, "restart should clear progress")
    require(restartedTask.progressStage == nil, "restart should clear progress stage")
    require(
        !FileManager.default.fileExists(
            atPath: store.taskDirectoryURL(for: task.id).appendingPathComponent("error.log").path
        ),
        "restart should remove stale error log"
    )
    require(
        FileManager.default.fileExists(
            atPath: store.taskDirectoryURL(for: task.id).appendingPathComponent("source.m4a").path
        ),
        "restart should keep source audio copy"
    )
    require(
        !FileManager.default.fileExists(
            atPath: store.taskDirectoryURL(for: task.id).appendingPathComponent("audio-segments").path
        ),
        "restart should remove stale audio segment workspace"
    )

    try store.deleteTask(id: task.id)
    let tasksAfterDelete = try store.load()
    require(tasksAfterDelete.isEmpty, "delete should remove task record")
    require(!FileManager.default.fileExists(atPath: store.taskDirectoryURL(for: task.id).path), "delete should remove task directory")
    require(FileManager.default.fileExists(atPath: originalAudio.path), "delete should keep original user file")
}

func testTaskStorePauseResumeTransitions() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("state-machine.m4a")
    try Data("state machine audio".utf8).write(to: audio)

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()

    let pendingTask = try store.createTask(fromAudioURL: audio, filename: "pending.m4a")

    var runningTask = try store.createTask(fromAudioURL: audio, filename: "running.m4a")
    runningTask.status = .running
    runningTask.startedAt = Date(timeIntervalSince1970: 100)
    runningTask.errorLogPath = store.taskDirectoryURL(for: runningTask.id)
        .appendingPathComponent("error.log")
        .path
    runningTask.progressFraction = 0.42
    try store.update(runningTask)

    var doneTask = try store.createTask(fromAudioURL: audio, filename: "done.m4a")
    let doneTranscriptURL = store.taskDirectoryURL(for: doneTask.id).appendingPathComponent("transcript.json")
    try writeUsableTranscript(to: doneTranscriptURL, taskId: doneTask.id, text: "done transcript")
    doneTask.status = .done
    doneTask.completedAt = Date(timeIntervalSince1970: 200)
    doneTask.transcriptPath = doneTranscriptURL.path
    try store.update(doneTask)

    var failedTask = try store.createTask(fromAudioURL: audio, filename: "failed.m4a")
    let failedTaskDirectory = store.taskDirectoryURL(for: failedTask.id)
    let failedTranscriptURL = failedTaskDirectory.appendingPathComponent("transcript.json")
    let failedAlignmentURL = failedTaskDirectory.appendingPathComponent("alignment.json")
    let failedErrorURL = failedTaskDirectory.appendingPathComponent("error.log")
    try Data("{\"segments\":[]}".utf8).write(to: failedTranscriptURL)
    try Data("{\"chunks\":[]}".utf8).write(to: failedAlignmentURL)
    try Data("stale failure".utf8).write(to: failedErrorURL)
    failedTask.status = .failed
    failedTask.failedAt = Date(timeIntervalSince1970: 300)
    failedTask.transcriptPath = failedTranscriptURL.path
    failedTask.errorLogPath = failedErrorURL.path
    failedTask.progressFraction = 0.7
    try store.update(failedTask)

    let ids = Set([pendingTask.id, runningTask.id, doneTask.id, failedTask.id])
    let paused = try store.pauseTasks(ids: ids)
    requireEqual(Set(paused.map(\.id)), Set([pendingTask.id, runningTask.id]), "pause should only affect pending and running tasks")

    var tasksById = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.id, $0) })
    let pausedPending = requireUnwrapped(tasksById[pendingTask.id], "pending task should remain after pause")
    requireEqual(pausedPending.status, .paused, "pending task should pause")
    require(pausedPending.startedAt == nil, "paused pending task should not keep startedAt")
    require(pausedPending.errorLogPath == nil, "paused pending task should clear error path")
    require(pausedPending.progressFraction == nil, "paused pending task should clear progress")

    let pausedRunning = requireUnwrapped(tasksById[runningTask.id], "running task should remain after pause")
    requireEqual(pausedRunning.status, .paused, "running task should pause")
    require(pausedRunning.startedAt == nil, "paused running task should clear startedAt")
    require(pausedRunning.errorLogPath == nil, "paused running task should clear error path")
    require(pausedRunning.progressFraction == nil, "paused running task should clear progress")

    let untouchedDone = requireUnwrapped(tasksById[doneTask.id], "done task should remain after pause")
    requireEqual(untouchedDone.status, .done, "pause should not affect done task")
    requireEqual(untouchedDone.transcriptPath, doneTranscriptURL.path, "pause should not clear done transcript")

    let untouchedFailed = requireUnwrapped(tasksById[failedTask.id], "failed task should remain after pause")
    requireEqual(untouchedFailed.status, .failed, "pause should not affect failed task")
    requireEqual(untouchedFailed.errorLogPath, failedErrorURL.path, "pause should not clear failed task error path")

    let resumed = try store.resumeTasks(ids: ids)
    requireEqual(
        Set(resumed.map(\.id)),
        Set([pendingTask.id, runningTask.id, failedTask.id]),
        "resume should restart paused and failed tasks but ignore done tasks"
    )

    tasksById = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.id, $0) })
    let resumedPending = requireUnwrapped(tasksById[pendingTask.id], "pending task should remain after resume")
    requireEqual(resumedPending.status, .pending, "paused pending task should resume to pending")

    let resumedRunning = requireUnwrapped(tasksById[runningTask.id], "running task should remain after resume")
    requireEqual(resumedRunning.status, .pending, "paused running task should resume to pending")

    let resumedFailed = requireUnwrapped(tasksById[failedTask.id], "failed task should remain after resume")
    requireEqual(resumedFailed.status, .pending, "failed task should restart to pending")
    require(resumedFailed.failedAt == nil, "restarted failed task should clear failedAt")
    require(resumedFailed.transcriptPath == nil, "restarted failed task should clear transcript path")
    require(resumedFailed.errorLogPath == nil, "restarted failed task should clear error path")
    require(resumedFailed.progressFraction == nil, "restarted failed task should clear progress")
    require(!FileManager.default.fileExists(atPath: failedTranscriptURL.path), "restart should remove stale transcript")
    require(!FileManager.default.fileExists(atPath: failedAlignmentURL.path), "restart should remove stale alignment")
    require(!FileManager.default.fileExists(atPath: failedErrorURL.path), "restart should remove stale error log")
    require(
        FileManager.default.fileExists(atPath: failedTaskDirectory.appendingPathComponent("source.m4a").path),
        "restart should keep failed task source audio"
    )

    let stillDone = requireUnwrapped(tasksById[doneTask.id], "done task should remain after resume")
    requireEqual(stillDone.status, .done, "resume should not affect done task")
    requireEqual(stillDone.transcriptPath, doneTranscriptURL.path, "resume should not clear done transcript")
}

func testLegacyTaskDecodingDefaultsMediaKindToAudio() throws {
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "filename": "legacy.m4a",
      "localAudioPath": "/tmp/legacy.m4a",
      "durationSec": 1,
      "fileSizeBytes": 1,
      "status": "pending",
      "createdAt": "2026-07-08T00:00:00Z"
    }
    """

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let task = try decoder.decode(TranscriptionTask.self, from: Data(json.utf8))
    requireEqual(task.mediaKind, .audio, "legacy tasks should default media kind to audio")
}

func testTaskStoreRecoversInterruptedRunningTasks() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("recover.m4a")
    try Data("recover audio".utf8).write(to: audio)

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    var runningTask = try store.createTask(fromAudioURL: audio)
    runningTask.status = .running
    runningTask.startedAt = Date(timeIntervalSince1970: 100)
    runningTask.transcriptPath = store.taskDirectoryURL(for: runningTask.id)
        .appendingPathComponent("transcript.json")
        .path
    runningTask.errorLogPath = store.taskDirectoryURL(for: runningTask.id)
        .appendingPathComponent("error.log")
        .path
    runningTask.progressFraction = 0.4
    try store.update(runningTask)

    let recovered = try store.recoverInterruptedTasks()
    requireEqual(recovered.count, 1, "one running task should be recovered")

    let recoveredTask = requireUnwrapped(try store.load().first { $0.id == runningTask.id }, "recovered task should exist")
    requireEqual(recoveredTask.status, .pending, "running task should recover to pending")
    require(recoveredTask.startedAt == nil, "recovered task should clear startedAt")
    require(recoveredTask.transcriptPath == nil, "recovered task should clear transcript path")
    require(recoveredTask.errorLogPath == nil, "recovered task should clear error log path")
    require(recoveredTask.progressFraction == nil, "recovered task should clear progress")
}

func testTaskStoreRepairsInvalidCompletedTasks() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("invalid-done.m4a")
    try Data("invalid done audio".utf8).write(to: audio)

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    var task = try store.createTask(fromAudioURL: audio)
    task.status = .done
    task.completedAt = Date(timeIntervalSince1970: 200)
    task.transcriptPath = store.taskDirectoryURL(for: task.id)
        .appendingPathComponent("missing-transcript.json")
        .path
    task.progressFraction = 1
    try store.update(task)

    let repaired = try store.repairInvalidCompletedTasks()
    requireEqual(repaired.count, 1, "invalid completed task should be repaired")

    let repairedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "repaired completed task should exist")
    requireEqual(repairedTask.status, .failed, "invalid completed task should become failed")
    require(repairedTask.failedAt != nil, "repaired completed task should set failedAt")
    require(repairedTask.transcriptPath == nil, "repaired completed task should clear transcript path")
    require(repairedTask.progressFraction == nil, "repaired completed task should clear progress")

    let errorLogPath = requireUnwrapped(repairedTask.errorLogPath, "repaired completed task should write error log")
    require(FileManager.default.fileExists(atPath: errorLogPath), "repaired completed task error log should exist")
    let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
    require(errorLog.contains("completed task transcript file is missing"), "error log should explain missing transcript")
}

func testTaskStoreRepairsFailedTasksWithValidTranscript() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("false-failed.m4a")
    try Data("false failed audio".utf8).write(to: audio)

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    var task = try store.createTask(fromAudioURL: audio)
    let taskDirectory = store.taskDirectoryURL(for: task.id)
    let transcriptURL = taskDirectory.appendingPathComponent("transcript.json")
    let errorLogURL = taskDirectory.appendingPathComponent("error.log")
    try writeUsableTranscript(to: transcriptURL, taskId: task.id)
    try Data("stale error".utf8).write(to: errorLogURL)

    task.status = .failed
    task.failedAt = Date(timeIntervalSince1970: 300)
    task.errorLogPath = errorLogURL.path
    task.progressFraction = 0.9
    try store.update(task)

    let repaired = try store.repairFailedTasksWithValidTranscript()
    requireEqual(repaired.count, 1, "failed task with usable transcript should be repaired")

    let repairedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "repaired failed task should exist")
    requireEqual(repairedTask.status, .done, "failed task with transcript should become done")
    require(repairedTask.completedAt != nil, "repaired failed task should set completedAt")
    require(repairedTask.failedAt == nil, "repaired failed task should clear failedAt")
    requireEqual(repairedTask.transcriptPath, transcriptURL.path, "repaired failed task should point to transcript")
    require(repairedTask.errorLogPath == nil, "repaired failed task should clear stale error path")
    require(repairedTask.progressFraction == nil, "repaired failed task should clear progress")

    let loadedTranscript = try TranscriptStore.load(from: transcriptURL)
    requireEqual(loadedTranscript.text, "restored transcript", "repaired transcript should remain readable")
}

func testTaskStoreRejectsTranscriptFromWrongTaskDuringRepair() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("wrong-task-repair.m4a")
    try Data("wrong task repair audio".utf8).write(to: audio)

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    var task = try store.createTask(fromAudioURL: audio)
    let transcriptURL = store.taskDirectoryURL(for: task.id).appendingPathComponent("transcript.json")
    try writeUsableTranscript(to: transcriptURL, taskId: UUID(), text: "wrong task transcript")

    task.status = .failed
    task.failedAt = Date(timeIntervalSince1970: 400)
    try store.update(task)

    let repairedFailed = try store.repairFailedTasksWithValidTranscript()
    requireEqual(repairedFailed.count, 0, "failed repair should not accept transcript with mismatched task id")
    let stillFailed = requireUnwrapped(try store.load().first { $0.id == task.id }, "wrong task repair target should exist")
    requireEqual(stillFailed.status, .failed, "wrong task transcript should leave failed task failed")

    var completedTask = stillFailed
    completedTask.status = .done
    completedTask.completedAt = Date(timeIntervalSince1970: 401)
    completedTask.transcriptPath = transcriptURL.path
    try store.update(completedTask)

    let repairedDone = try store.repairInvalidCompletedTasks()
    requireEqual(repairedDone.count, 1, "completed repair should reject transcript with mismatched task id")
    let repairedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "repaired wrong task completed should exist")
    requireEqual(repairedTask.status, .failed, "wrong task completed transcript should become failed")
    let errorLogPath = requireUnwrapped(repairedTask.errorLogPath, "wrong task completed repair should write error log")
    let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
    require(errorLog.contains("task id mismatch"), "wrong task repair error should mention task id mismatch")
}

func testTaskStoreRejectsTranscriptOutsideTaskDirectoryDuringRepair() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("outside-transcript-repair.m4a")
    try Data("outside transcript repair audio".utf8).write(to: audio)

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    var task = try store.createTask(fromAudioURL: audio)
    let outsideTranscriptURL = root.appendingPathComponent("outside-transcript.json")
    try writeUsableTranscript(to: outsideTranscriptURL, taskId: task.id, text: "outside transcript")

    task.status = .done
    task.completedAt = Date(timeIntervalSince1970: 500)
    task.transcriptPath = outsideTranscriptURL.path
    try store.update(task)

    let repaired = try store.repairInvalidCompletedTasks()
    requireEqual(repaired.count, 1, "completed repair should reject transcript outside task directory")
    let repairedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "outside transcript task should exist")
    requireEqual(repairedTask.status, .failed, "outside transcript should make completed task failed")
    require(repairedTask.transcriptPath == nil, "outside transcript repair should clear transcript path")
}

func testWorkerProtocolUsesSnakeCaseJSON() throws {
    let requestId = UUID()
    let taskId = UUID()
    let request = WorkerRequest(
        requestId: requestId,
        taskId: taskId,
        audioPath: "/tmp/source.m4a",
        outputDir: "/tmp/task",
        language: "zh",
        pipeline: "direct_single_pass",
        durationSec: 12.5
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let requestData = try encoder.encode(request)
    let requestObject = try JSONDecoder().decode([String: JSONValue].self, from: requestData)

    requireJSONString(requestObject["type"], "transcribe", "request type should encode")
    requireJSONString(requestObject["request_id"], requestId.uuidString, "request_id should be snake case")
    requireJSONString(requestObject["task_id"], taskId.uuidString, "task_id should be snake case")
    requireJSONString(requestObject["audio_path"], "/tmp/source.m4a", "audio_path should be snake case")
    requireJSONString(requestObject["output_dir"], "/tmp/task", "output_dir should be snake case")
    requireJSONString(requestObject["language"], "zh", "language should encode")
    requireJSONString(requestObject["pipeline"], "direct_single_pass", "pipeline should encode")
    requireJSONNumber(requestObject["duration_sec"], 12.5, "duration_sec should be snake case")
    require(requestObject["requestId"] == nil, "request should not encode camelCase requestId")
    require(requestObject["taskId"] == nil, "request should not encode camelCase taskId")

    let eventJSON = """
    {
      "type": "progress",
      "request_id": "\(requestId.uuidString)",
      "task_id": "\(taskId.uuidString)",
      "stage": "transcribing",
      "completed_segments": 1,
      "total_segments": 3,
      "duration_sec": 12.5
    }
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let event = try decoder.decode(WorkerEvent.self, from: Data(eventJSON.utf8))

    requireEqual(event.type, WorkerEventType.progress, "worker event type")
    requireEqual(event.requestId, requestId, "worker event request id")
    requireEqual(event.taskId, taskId, "worker event task id")
    requireEqual(event.completedSegments, 1, "worker event completed segments")
    requireEqual(event.totalSegments, 3, "worker event total segments")
    requireEqual(event.durationSec, 12.5, "worker event duration")
}

func testASRWorkerClientCapturesNonZeroExitAndStderr() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let workerURL = try writeWorkerScript(
        named: "worker_exit.py",
        in: root,
        body: """
        import sys

        sys.stderr.write("worker diagnostic before exit\\n")
        sys.exit(2)
        """
    )
    let outputDir = root.appendingPathComponent("output", isDirectory: true)
    let client = makeTestWorkerClient(workerURL: workerURL)

    do {
        _ = try client.transcribe(task: makeTestTask(), outputDir: outputDir)
        fail("non-zero worker should throw")
    } catch ASRWorkerClient.ClientError.workerExited(let status, let stderrText) {
        requireEqual(status, 2, "worker exit status should be preserved")
        require(stderrText.contains("worker diagnostic before exit"), "worker stderr should be preserved")
    }

    let errorLog = try String(
        contentsOf: outputDir.appendingPathComponent("error.log"),
        encoding: .utf8
    )
    require(errorLog.contains("worker diagnostic before exit"), "error log should capture stderr")
    require(errorLog.contains("worker exited with status 2"), "error log should capture exit status")
}

func testASRWorkerClientRequiresTerminalEvent() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let workerURL = try writeWorkerScript(
        named: "worker_missing_terminal.py",
        in: root,
        body: """
        import json
        import sys

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 1,
            "total_segments": 2
        }), flush=True)
        """
    )
    let task = makeTestTask()
    let client = makeTestWorkerClient(workerURL: workerURL)

    do {
        _ = try client.transcribe(task: task, outputDir: root.appendingPathComponent("output", isDirectory: true))
        fail("worker without terminal event should throw")
    } catch ASRWorkerClient.ClientError.missingCompletionEvent(let taskId) {
        requireEqual(taskId, task.id, "missing completion should report task id")
    }
}

func testASRWorkerClientRejectsMalformedWorkerOutput() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let workerURL = try writeWorkerScript(
        named: "worker_malformed_output.py",
        in: root,
        body: """
        import sys

        print("this is not json", flush=True)
        """
    )
    let client = makeTestWorkerClient(workerURL: workerURL)

    do {
        _ = try client.transcribe(
            task: makeTestTask(),
            outputDir: root.appendingPathComponent("output", isDirectory: true)
        )
        fail("malformed worker stdout should throw")
    } catch ASRWorkerClient.ClientError.missingCompletionEvent {
        fail("malformed worker stdout should fail before missing terminal event")
    } catch {
        // Expected: malformed stdout should surface the JSON decoding failure.
    }
}

func testASRWorkerClientTimeoutWritesErrorLog() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let workerURL = try writeWorkerScript(
        named: "worker_timeout.py",
        in: root,
        body: """
        import json
        import sys
        import time

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 0,
            "total_segments": 1
        }), flush=True)
        time.sleep(10)
        """
    )
    let outputDir = root.appendingPathComponent("output", isDirectory: true)
    let client = makeTestWorkerClient(workerURL: workerURL, timeoutSeconds: 0.2)

    do {
        _ = try client.transcribe(task: makeTestTask(), outputDir: outputDir)
        fail("timed out worker should throw")
    } catch ASRWorkerClient.ClientError.workerTimedOut(let timeout) {
        require(timeout > 0, "timeout should be reported")
    }

    let errorLog = try String(
        contentsOf: outputDir.appendingPathComponent("error.log"),
        encoding: .utf8
    )
    require(errorLog.contains("worker timed out"), "timeout should be written to error log")
}

func testAuralChildProcessRegistryTerminatesRegisteredProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()
    AuralChildProcessRegistry.shared.register(process)
    require(process.isRunning, "registered process should start running")

    AuralChildProcessRegistry.shared.terminateAll()
    require(!process.isRunning, "registered process should be terminated")
}

func testTranscriptionQueueMarksWorkerFailedEventAsFailedTask() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("queue-failed.m4a")
    try Data("queue failed audio".utf8).write(to: audio)

    let workerURL = try writeWorkerScript(
        named: "worker_failed_event.py",
        in: root,
        body: """
        import json
        import pathlib
        import sys

        request = json.loads(sys.stdin.readline())
        error_log = pathlib.Path(request["output_dir"]) / "worker-error.log"
        error_log.parent.mkdir(parents=True, exist_ok=True)
        error_log.write_text("worker reported failure\\n", encoding="utf-8")
        print(json.dumps({
            "type": "failed",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "error_code": "qa_forced_failure",
            "error_log_path": str(error_log)
        }), flush=True)
        """
    )

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    let task = try store.createTask(fromAudioURL: audio)
    let queue = TranscriptionQueue(
        store: store,
        workerClient: makeTestWorkerClient(workerURL: workerURL)
    )

    let processed = try queue.drainPendingTasks()
    requireEqual(processed.count, 1, "failed worker event should finish one queue item")
    requireEqual(processed[0].status, .failed, "failed worker event should return failed task")

    let failedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "failed queue task should exist")
    requireEqual(failedTask.status, .failed, "failed worker event should persist failed status")
    require(failedTask.failedAt != nil, "failed worker event should set failedAt")
    requireEqual(failedTask.errorLogPath?.hasSuffix("worker-error.log"), true, "failed worker event should preserve error log path")
    require(failedTask.progressFraction == nil, "failed worker event should clear progress")
}

func testTranscriptionQueueMarksMalformedWorkerOutputAsFailedTask() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("queue-malformed-output.m4a")
    try Data("queue malformed output audio".utf8).write(to: audio)

    let workerURL = try writeWorkerScript(
        named: "worker_malformed_queue.py",
        in: root,
        body: """
        import sys

        print("this is not json", flush=True)
        """
    )

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    let task = try store.createTask(fromAudioURL: audio)
    let queue = TranscriptionQueue(
        store: store,
        workerClient: makeTestWorkerClient(workerURL: workerURL)
    )

    do {
        _ = try queue.drainPendingTasks()
        fail("malformed worker output should make queue throw")
    } catch {
        let failedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "malformed output task should exist")
        requireEqual(failedTask.status, .failed, "malformed worker output should persist failed status")
        require(failedTask.failedAt != nil, "malformed worker output should set failedAt")
        require(failedTask.progressFraction == nil, "malformed worker output should clear progress")
        let errorLogPath = requireUnwrapped(failedTask.errorLogPath, "malformed worker output should write error log")
        let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
        require(!errorLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "malformed worker output error log should not be empty")
    }
}

func testTranscriptionQueueTreatsInvalidCompletedEventAsFailedTask() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("queue-invalid-completed.m4a")
    try Data("queue invalid completed audio".utf8).write(to: audio)

    let workerURL = try writeWorkerScript(
        named: "worker_invalid_completed.py",
        in: root,
        body: """
        import json
        import sys

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "completed",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "transcript_path": request["output_dir"] + "/missing-transcript.json",
            "duration_sec": 1.0
        }), flush=True)
        """
    )

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    let task = try store.createTask(fromAudioURL: audio)
    let queue = TranscriptionQueue(
        store: store,
        workerClient: makeTestWorkerClient(workerURL: workerURL)
    )

    let processed = try queue.drainPendingTasks()
    requireEqual(processed.count, 1, "invalid completed event should finish one queue item")
    requireEqual(processed[0].status, .failed, "invalid completed event should return failed task")

    let failedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "invalid completed task should exist")
    requireEqual(failedTask.status, .failed, "invalid completed event should persist failed status")
    require(failedTask.transcriptPath == nil, "invalid completed event should clear transcript path")
    require(failedTask.progressFraction == nil, "invalid completed event should clear progress")

    let errorLogPath = requireUnwrapped(failedTask.errorLogPath, "invalid completed event should write error log")
    let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
    require(errorLog.contains("completed event transcript file is missing"), "invalid completed error log should explain missing transcript")
}

func testTranscriptionQueueRejectsCompletedTranscriptWithWrongTaskId() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("queue-wrong-task-transcript.m4a")
    try Data("queue wrong task transcript audio".utf8).write(to: audio)

    let wrongTaskId = UUID()
    let workerURL = try writeWorkerScript(
        named: "worker_wrong_task_transcript.py",
        in: root,
        body: """
        import json
        import pathlib
        import sys

        request = json.loads(sys.stdin.readline())
        output_dir = pathlib.Path(request["output_dir"])
        output_dir.mkdir(parents=True, exist_ok=True)
        transcript_path = output_dir / "transcript.json"
        transcript_path.write_text(json.dumps({
            "task_id": "\(wrongTaskId.uuidString)",
            "audio_duration_sec": 1.0,
            "created_at": "2026-07-08T00:00:00Z",
            "segments": [{"start_sec": 0.0, "end_sec": 1.0, "text": "wrong task"}],
            "text": "wrong task"
        }), encoding="utf-8")
        print(json.dumps({
            "type": "completed",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "transcript_path": str(transcript_path),
            "duration_sec": 1.0
        }), flush=True)
        """
    )

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    let task = try store.createTask(fromAudioURL: audio)
    let queue = TranscriptionQueue(
        store: store,
        workerClient: makeTestWorkerClient(workerURL: workerURL)
    )

    let processed = try queue.drainPendingTasks()
    requireEqual(processed.count, 1, "wrong task completed event should finish one queue item")
    requireEqual(processed[0].status, .failed, "wrong task transcript should return failed task")

    let failedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "wrong task completed task should exist")
    requireEqual(failedTask.status, .failed, "wrong task transcript should persist failed status")
    require(failedTask.transcriptPath == nil, "wrong task transcript should not be attached")

    let errorLogPath = requireUnwrapped(failedTask.errorLogPath, "wrong task transcript should write error log")
    let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
    require(errorLog.contains("task id mismatch"), "wrong task error log should mention task id mismatch")
}

func testTranscriptionQueuePersistsProgressWhileRunningAndClearsItOnCompletion() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("queue-progress.m4a")
    try Data("queue progress audio".utf8).write(to: audio)

    let releaseMarker = root.appendingPathComponent("release-progress-worker")
    let workerURL = try writeWorkerScript(
        named: "worker_progress_then_complete.py",
        in: root,
        body: """
        import json
        import pathlib
        import sys
        import time

        release_marker = pathlib.Path("\(releaseMarker.path)")
        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 1,
            "total_segments": 4
        }), flush=True)
        while not release_marker.exists():
            time.sleep(0.05)
        output_dir = pathlib.Path(request["output_dir"])
        output_dir.mkdir(parents=True, exist_ok=True)
        transcript_path = output_dir / "transcript.json"
        transcript_path.write_text(json.dumps({
            "task_id": request["task_id"],
            "audio_duration_sec": 2.0,
            "created_at": "2026-07-08T00:00:00Z",
            "segments": [{"start_sec": 0.0, "end_sec": 2.0, "text": "progress done"}],
            "text": "progress done"
        }), encoding="utf-8")
        print(json.dumps({
            "type": "completed",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "transcript_path": str(transcript_path),
            "duration_sec": 2.0
        }), flush=True)
        """
    )

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    let task = try store.createTask(fromAudioURL: audio)
    let queue = TranscriptionQueue(
        store: store,
        workerClient: makeTestWorkerClient(workerURL: workerURL)
    )

    let harness = QueueRunHarness(queue: queue)
    harness.startNextPendingTask()

    try waitUntil("progress event should be persisted while task is running") {
        let runningTask = try store.load().first { $0.id == task.id }
        guard runningTask?.status == .running,
              let progress = runningTask?.progressFraction else {
            return false
        }
        return abs(progress - 0.25) < 0.0001 && runningTask?.progressStage == "transcribing"
    }

    let eventLogURL = store.taskDirectoryURL(for: task.id).appendingPathComponent("worker-events.jsonl")
    let eventLog = try String(contentsOf: eventLogURL, encoding: .utf8)
    require(eventLog.contains("\"stage\":\"transcribing\""), "worker event log should persist progress stage")

    try Data("release".utf8).write(to: releaseMarker)
    try waitUntil("progress worker should finish after release marker") {
        harness.sink.result != nil
    }

    guard let result = harness.sink.result else {
        fail("progress worker result should be captured")
    }
    switch result {
    case .success(let processed):
        let completed = requireUnwrapped(processed, "progress worker should return completed task")
        requireEqual(completed.status, .done, "progress worker should complete task")
    case .failure(let error):
        fail("progress worker should not fail: \(error)")
    }

    let completedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "progress task should exist after completion")
    requireEqual(completedTask.status, .done, "progress task should persist done status")
    require(completedTask.progressFraction == nil, "completed task should clear transient progress")
    require(completedTask.progressStage == nil, "completed task should clear transient progress stage")
    let transcriptPath = requireUnwrapped(completedTask.transcriptPath, "completed task should keep transcript path")
    let transcript = try TranscriptStore.load(from: URL(fileURLWithPath: transcriptPath))
    requireEqual(transcript.text, "progress done", "completed progress transcript should remain readable")
}

func testTranscriptionQueueLeavesTaskPausedWhenStoppedDuringWorkerRun() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appendingPathComponent("queue-pause-running.m4a")
    try Data("queue pause running audio".utf8).write(to: audio)

    let workerURL = try writeWorkerScript(
        named: "worker_progress_then_wait.py",
        in: root,
        body: """
        import json
        import sys
        import time

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 2,
            "total_segments": 5
        }), flush=True)
        while True:
            time.sleep(0.1)
        """
    )

    let store = TaskStore(rootURL: root.appendingPathComponent("data", isDirectory: true))
    try store.bootstrap()
    let task = try store.createTask(fromAudioURL: audio)
    let queue = TranscriptionQueue(
        store: store,
        workerClient: makeTestWorkerClient(workerURL: workerURL, timeoutSeconds: 10)
    )

    let harness = QueueRunHarness(queue: queue)
    harness.startNextPendingTask()

    try waitUntil("running task should persist worker progress before pause") {
        let runningTask = try store.load().first { $0.id == task.id }
        guard runningTask?.status == .running,
              let progress = runningTask?.progressFraction else {
            return false
        }
        return abs(progress - 0.4) < 0.0001
    }

    let pausedTasks = try store.pauseTasks(ids: [task.id])
    requireEqual(pausedTasks.count, 1, "pause should update the running queue task")

    try waitUntil("queue should return after running task is paused") {
        harness.sink.result != nil
    }

    guard let result = harness.sink.result else {
        fail("paused queue result should be captured")
    }
    switch result {
    case .success(let processed):
        let paused = requireUnwrapped(processed, "paused queue should return the current task")
        requireEqual(paused.status, .paused, "paused queue should return paused task")
    case .failure(let error):
        fail("paused queue should not surface worker cancellation as failure: \(error)")
    }

    let pausedTask = requireUnwrapped(try store.load().first { $0.id == task.id }, "paused queue task should exist")
    requireEqual(pausedTask.status, .paused, "paused queue task should stay paused")
    require(pausedTask.completedAt == nil, "paused queue task should not be marked completed")
    require(pausedTask.transcriptPath == nil, "paused queue task should not get a transcript path")
    require(pausedTask.errorLogPath == nil, "paused queue cancellation should not write an error log")
    require(pausedTask.progressFraction == nil, "paused queue task should clear transient progress")
}

func testASRWorkerClientCancellationReportsTaskId() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let workerURL = try writeWorkerScript(
        named: "worker_cancelled.py",
        in: root,
        body: """
        import json
        import sys
        import time

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 0,
            "total_segments": 1
        }), flush=True)
        time.sleep(10)
        """
    )
    let task = makeTestTask()
    let client = makeTestWorkerClient(workerURL: workerURL, timeoutSeconds: 5)

    do {
        _ = try client.transcribe(
            task: task,
            outputDir: root.appendingPathComponent("output", isDirectory: true),
            shouldCancel: { true }
        )
        fail("cancelled worker should throw")
    } catch ASRWorkerClient.ClientError.cancelled(let taskId) {
        requireEqual(taskId, task.id, "cancelled worker should report task id")
    }
}

func testModelResourceStatusAndCompatibility() throws {
    requireEqual(ModelResourceConfiguration.default.profile, .balanced, "default model profile should be balanced")
    require(ModelResourceConfiguration.default.alignmentEnabled, "default alignment should be enabled")

    let fastWithoutAligner = ModelResourceConfiguration(profile: .fast, alignmentEnabled: false)
    require(
        ModelResourceStatus.needsDownload(
            configuration: fastWithoutAligner,
            allowsProfileSelection: false
        ).detail.contains("0.8GB"),
        "fast no-aligner download text should describe ASR-only size"
    )

    let balancedWithAligner = ModelResourceConfiguration(profile: .balanced, alignmentEnabled: true)
    require(
        ModelResourceStatus.needsDownload(
            configuration: balancedWithAligner,
            allowsProfileSelection: false
        ).detail.contains("2.6GB"),
        "balanced with aligner download text should include aligner estimate"
    )
    require(
        ModelResourceStatus.needsDownload(
            configuration: balancedWithAligner,
            allowsProfileSelection: true
        ).detail.contains("选择"),
        "profile selection status should describe selectable local model mode"
    )

    let oldMacStatus = RuntimeCompatibility.blockingStatus(
        currentVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0),
        isAppleSilicon: true
    )
    requireEqual(oldMacStatus?.phase, .failed, "old macOS should be blocked")
    requireEqual(oldMacStatus?.allowsRetry, false, "old macOS block should not allow retry")

    let intelStatus = RuntimeCompatibility.blockingStatus(
        currentVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
        isAppleSilicon: false
    )
    requireEqual(intelStatus?.phase, .failed, "Intel Mac should be blocked")
    requireEqual(intelStatus?.allowsRetry, false, "Intel block should not allow retry")

    let supportedStatus = RuntimeCompatibility.blockingStatus(
        currentVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
        isAppleSilicon: true
    )
    require(supportedStatus == nil, "Apple Silicon macOS 14 should pass compatibility gate")

    requireEqual(
        RuntimeCompatibility.effectiveProfile(
            .accurate,
            physicalMemoryBytes: ModelResourceProfile.accurateMinimumMemoryBytes - 1
        ),
        .balanced,
        "accurate profile should fall back to balanced below memory threshold"
    )
    requireEqual(
        RuntimeCompatibility.effectiveProfile(
            .accurate,
            physicalMemoryBytes: ModelResourceProfile.accurateMinimumMemoryBytes
        ),
        .accurate,
        "accurate profile should be allowed at memory threshold"
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let event = try decoder.decode(
        ModelResourceEvent.self,
        from: Data(#"{"type":"download_progress","profile":"balanced","downloaded_bytes":123,"total_bytes":456,"progress":0.27}"#.utf8)
    )
    requireEqual(event.type, "download_progress", "model resource event type")
    requireEqual(event.profile, "balanced", "model resource event profile")
    requireEqual(event.downloadedBytes, 123, "model resource downloaded bytes")
    requireEqual(event.totalBytes, 456, "model resource total bytes")
    require(abs((event.progress ?? 0) - 0.27) < 0.0001, "model resource progress")
}

func testRuntimePathsModelSelectionUsesEnvironmentAndConfig() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    try withTemporaryEnvironment([
        "AURAL_DATA_ROOT": root.appendingPathComponent("env-data", isDirectory: true).path,
        "AURAL_MODEL_PROFILE": "accurate",
        "AURAL_ALIGNMENT_ENABLED": "0",
        "AURAL_FORCE_MEMORY_BYTES": String(ModelResourceProfile.accurateMinimumMemoryBytes - 1)
    ]) {
        let config = RuntimePaths.selectedResourceConfiguration()
        requireEqual(config.profile, .balanced, "accurate profile should fall back when forced memory is low")
        requireEqual(config.alignmentEnabled, false, "environment should disable alignment")
    }

    try withTemporaryEnvironment([
        "AURAL_DATA_ROOT": root.appendingPathComponent("config-data", isDirectory: true).path,
        "AURAL_MODEL_PROFILE": nil,
        "AURAL_ALIGNMENT_ENABLED": nil,
        "AURAL_FORCE_MEMORY_BYTES": nil
    ]) {
        try RuntimePaths.saveSelectedResourceConfiguration(
            ModelResourceConfiguration(profile: .fast, alignmentEnabled: false)
        )

        let config = RuntimePaths.selectedResourceConfiguration()
        requireEqual(config.profile, .fast, "saved model profile should round-trip through config file")
        requireEqual(config.alignmentEnabled, false, "saved alignment preference should round-trip through config file")
        require(
            FileManager.default.fileExists(atPath: RuntimePaths.modelProfileConfigURL().path),
            "model profile config should be written under data root"
        )
    }
}

func testRuntimePathsModelAvailabilityAndWorkerEnvironmentUseCompleteLocalCache() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let modelRoot = root.appendingPathComponent("models", isDirectory: true)
    let fastModel = modelRoot.appendingPathComponent(ModelResourceProfile.fast.asrDirectoryName, isDirectory: true)
    let alignerModel = modelRoot.appendingPathComponent(RuntimePaths.alignerModelDirectoryName, isDirectory: true)

    try withTemporaryEnvironment([
        "AURAL_DATA_ROOT": root.appendingPathComponent("data", isDirectory: true).path,
        "AURAL_MODEL_ROOT": modelRoot.path,
        "AURAL_MODEL_PROFILE": "fast",
        "AURAL_ALIGNMENT_ENABLED": "1",
        "AURAL_ASR_MODEL": nil,
        "AURAL_ALIGNER_MODEL": nil
    ]) {
        require(RuntimePaths.availableASRModelURL(profile: .fast) == nil, "missing ASR cache should not look available")

        try writeSparseModelSkeleton(
            to: fastModel,
            safetensorsBytes: ModelResourceProfile.fast.asrMinSafetensorsBytes - 1
        )
        require(RuntimePaths.availableASRModelURL(profile: .fast) == nil, "undersized ASR safetensors should not look available")

        try writeSparseModelSkeleton(
            to: fastModel,
            safetensorsBytes: ModelResourceProfile.fast.asrMinSafetensorsBytes,
            includeRequiredFiles: false,
            includeCompletionMarker: true
        )
        require(
            RuntimePaths.availableASRModelURL(profile: .fast) == nil,
            "ASR cache missing required tokenizer/generation files should not look available"
        )

        try writeSparseModelSkeleton(
            to: fastModel,
            safetensorsBytes: ModelResourceProfile.fast.asrMinSafetensorsBytes
        )
        require(
            RuntimePaths.availableASRModelURL(profile: .fast) == nil,
            "ASR cache without completion marker should not look available"
        )

        try writeSparseModelSkeleton(
            to: fastModel,
            safetensorsBytes: ModelResourceProfile.fast.asrMinSafetensorsBytes,
            includeCompletionMarker: true
        )
        requireEqual(
            RuntimePaths.availableASRModelURL(profile: .fast)?.path,
            fastModel.path,
            "complete ASR cache should be selected from model root"
        )
        require(
            RuntimePaths.requiredModelsAreAvailable(profile: .fast, alignmentEnabled: false),
            "ASR-only resources should be available when alignment is disabled"
        )
        require(
            !RuntimePaths.requiredModelsAreAvailable(profile: .fast, alignmentEnabled: true),
            "alignment-enabled resources should require aligner cache"
        )

        try writeSparseModelSkeleton(to: alignerModel, safetensorsBytes: 500_000_000)
        require(
            RuntimePaths.availableAlignerModelURL() == nil,
            "aligner cache without completion marker should not look available"
        )
        try writeSparseModelSkeleton(
            to: alignerModel,
            safetensorsBytes: 500_000_000,
            includeCompletionMarker: true
        )
        requireEqual(
            RuntimePaths.availableAlignerModelURL()?.path,
            alignerModel.path,
            "complete aligner cache should be selected from model root"
        )
        require(
            RuntimePaths.requiredModelsAreAvailable(profile: .fast, alignmentEnabled: true),
            "ASR plus aligner resources should be available when both caches are complete"
        )

        let environment = RuntimePaths.workerEnvironment()
        requireEqual(requireUnwrapped(environment["AURAL_MODEL_ROOT"], "worker env model root"), modelRoot.path, "worker env model root")
        requireEqual(requireUnwrapped(environment["AURAL_MODEL_PROFILE"], "worker env model profile"), "fast", "worker env model profile")
        requireEqual(requireUnwrapped(environment["AURAL_ALIGNMENT_ENABLED"], "worker env alignment"), "1", "worker env alignment")
        requireEqual(requireUnwrapped(environment["AURAL_ASR_MODEL"], "worker env ASR model"), fastModel.path, "worker env ASR model")
        requireEqual(requireUnwrapped(environment["AURAL_ALIGNER_MODEL"], "worker env aligner model"), alignerModel.path, "worker env aligner model")
    }
}

func testModelResourcePreparerReportsMissingScriptWhenResourcesNeedPreparation() throws {
    guard !RuntimePaths.requiredRuntimeIsAvailable() else {
        print("Skipping missing preparer script test because a runtime probe is active")
        return
    }

    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let missingScript = root.appendingPathComponent("missing_prepare.py")
    let modelRoot = root.appendingPathComponent("models", isDirectory: true)
    let preparer = ModelResourcePreparer(
        profile: .fast,
        alignmentEnabled: false,
        pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/env"),
        scriptURL: missingScript,
        modelRootURL: modelRoot
    )

    do {
        try preparer.prepare { _ in
            fail("missing preparer script should not emit events")
        }
        fail("missing preparer script should throw")
    } catch ModelResourcePreparer.PreparerError.preparerScriptUnavailable(let path) {
        requireEqual(path, missingScript.path, "missing preparer script path should be reported")
    }
    require(!FileManager.default.fileExists(atPath: modelRoot.path), "missing script should not create model root")
}

func testModelResourcePreparerReportsScriptFailureAndKeepsEvents() throws {
    guard !RuntimePaths.requiredRuntimeIsAvailable() else {
        print("Skipping failing preparer script test because a runtime probe is active")
        return
    }

    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appendingPathComponent("failing_prepare.py")
    try Data(
        """
        import json
        import sys

        print(json.dumps({
            "type": "download_progress",
            "profile": "fast",
            "downloaded_bytes": 10,
            "total_bytes": 100,
            "progress": 0.1
        }), flush=True)
        print("not json", flush=True)
        sys.stderr.write("model download failed\\n")
        raise SystemExit(7)
        """.utf8
    ).write(to: script)

    let modelRoot = root.appendingPathComponent("models", isDirectory: true)
    let preparer = ModelResourcePreparer(
        profile: .fast,
        alignmentEnabled: false,
        pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/env"),
        scriptURL: script,
        modelRootURL: modelRoot
    )
    let sink = ModelResourceEventSink()

    do {
        try preparer.prepare { event in
            sink.append(event)
        }
        fail("failing preparer script should throw")
    } catch ModelResourcePreparer.PreparerError.failed(let status, let stderrText) {
        requireEqual(status, 7, "failing preparer exit status should be reported")
        require(stderrText.contains("model download failed"), "failing preparer stderr should be reported")
    }

    require(FileManager.default.fileExists(atPath: modelRoot.path), "preparer should create model root before running script")
    let events = sink.events
    let progressEvent = requireUnwrapped(events.first, "failing preparer should still emit valid progress events")
    requireEqual(progressEvent.type, "download_progress", "preparer progress event type")
    requireEqual(progressEvent.profile, "fast", "preparer progress event profile")
    requireEqual(progressEvent.downloadedBytes, 10, "preparer progress downloaded bytes")
    requireEqual(progressEvent.totalBytes, 100, "preparer progress total bytes")
    require(abs((progressEvent.progress ?? 0) - 0.1) < 0.0001, "preparer progress fraction")
}

func testTranscriptStoreRoundTripsMetadataAndLoadsAlignmentSidecar() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let transcriptURL = root.appendingPathComponent("transcript.json")
    let taskId = UUID()
    let transcript = Transcript(
        taskId: taskId,
        audioDurationSec: 42,
        createdAt: Date(timeIntervalSince1970: 1_782_950_400),
        segments: [
            TranscriptSegment(
                startSec: 0,
                endSec: 3.25,
                text: "显示文本",
                rawText: "原始文本",
                alignmentItemStart: 0,
                alignmentItemEnd: 2
            )
        ],
        text: "显示文本",
        rawText: "原始文本",
        normalizedText: "显示文本",
        metadata: [
            "timestamp_method": .string("qwen3_forced_aligner_paragraph"),
            "segment_count": .number(1),
            "itn": .object([
                "enabled": .bool(true),
                "status": .string("ok")
            ])
        ]
    )

    try TranscriptStore.save(transcript, to: transcriptURL)
    let loadedTranscript = try TranscriptStore.load(from: transcriptURL)

    requireEqual(loadedTranscript.taskId, taskId, "transcript task id should round trip")
    requireEqual(loadedTranscript.segments.count, 1, "transcript segments should round trip")
    requireEqual(loadedTranscript.segments[0].rawText, "原始文本", "segment raw text should round trip")
    requireEqual(loadedTranscript.segments[0].alignmentItemStart, 0, "alignment start should round trip")
    requireEqual(loadedTranscript.normalizedText, "显示文本", "normalized text should round trip")
    requireJSONString(
        loadedTranscript.metadata?["timestamp_method"],
        "qwen3_forced_aligner_paragraph",
        "metadata timestamp method should round trip"
    )
    requireJSONNumber(loadedTranscript.metadata?["segment_count"], 1, "metadata segment count should round trip")
    let missingAlignment = try TranscriptStore.loadAlignment(forTranscriptAt: transcriptURL)
    require(missingAlignment == nil, "missing alignment sidecar should be tolerated")

    let alignmentJSON = """
    {
      "version": 1,
      "created_at": "2026-07-08T00:00:00Z",
      "model": "Qwen3-ForcedAligner-0.6B-4bit",
      "runtime": "mlx_audio",
      "status": "ok",
      "chunks": [
        {
          "index": 1,
          "start_sec": 0.0,
          "end_sec": 3.25,
          "language": "zh",
          "status": "ok",
          "alignment_item_start": 0,
          "alignment_item_end": 2
        }
      ],
      "items": [
        {
          "index": 0,
          "chunk_index": 1,
          "text": "显",
          "start_sec": 0.1,
          "end_sec": 0.2,
          "duration_sec": 0.1
        }
      ]
    }
    """
    try Data(alignmentJSON.utf8).write(to: root.appendingPathComponent("alignment.json"))
    let alignment = try requireUnwrapped(
        TranscriptStore.loadAlignment(forTranscriptAt: transcriptURL),
        "alignment sidecar should load"
    )

    requireEqual(alignment.version, 1, "alignment version")
    requireEqual(alignment.status, "ok", "alignment status")
    requireEqual(alignment.chunks.first?.alignmentItemEnd, 2, "alignment chunk end")
    requireEqual(alignment.items.first?.text, "显", "alignment item text")
}

func testTranscriptStoreDecodesFractionalPythonTimestamp() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let taskId = UUID()
    let transcriptURL = root.appendingPathComponent("fractional-transcript.json")
    let transcriptJSON = """
    {
      "task_id": "\(taskId.uuidString)",
      "audio_duration_sec": 1.0,
      "created_at": "2026-07-07T10:01:12.806505+00:00",
      "segments": [
        {
          "start_sec": 0.0,
          "end_sec": 1.0,
          "text": "微秒时间"
        }
      ],
      "text": "微秒时间"
    }
    """
    try Data(transcriptJSON.utf8).write(to: transcriptURL)

    let transcript = try TranscriptStore.load(from: transcriptURL)
    requireEqual(transcript.taskId, taskId, "fractional timestamp transcript task id")
    requireEqual(transcript.text, "微秒时间", "fractional timestamp transcript text")
}

do {
    testMediaFileTypes()
    testTranscriptExportRenderer()
    testTranscriptExportRendererFallsBackToTopLevelTextWhenSegmentsAreEmpty()
    try testTaskStoreLifecycle()
    try testTaskStorePauseResumeTransitions()
    try testLegacyTaskDecodingDefaultsMediaKindToAudio()
    try testTaskStoreRecoversInterruptedRunningTasks()
    try testTaskStoreRepairsInvalidCompletedTasks()
    try testTaskStoreRepairsFailedTasksWithValidTranscript()
    try testTaskStoreRejectsTranscriptFromWrongTaskDuringRepair()
    try testTaskStoreRejectsTranscriptOutsideTaskDirectoryDuringRepair()
    try testWorkerProtocolUsesSnakeCaseJSON()
    try testASRWorkerClientCapturesNonZeroExitAndStderr()
    try testASRWorkerClientRequiresTerminalEvent()
    try testASRWorkerClientRejectsMalformedWorkerOutput()
    try testASRWorkerClientTimeoutWritesErrorLog()
    try testAuralChildProcessRegistryTerminatesRegisteredProcess()
    try testTranscriptionQueueMarksWorkerFailedEventAsFailedTask()
    try testTranscriptionQueueMarksMalformedWorkerOutputAsFailedTask()
    try testTranscriptionQueueTreatsInvalidCompletedEventAsFailedTask()
    try testTranscriptionQueueRejectsCompletedTranscriptWithWrongTaskId()
    try testTranscriptionQueuePersistsProgressWhileRunningAndClearsItOnCompletion()
    try testTranscriptionQueueLeavesTaskPausedWhenStoppedDuringWorkerRun()
    try testASRWorkerClientCancellationReportsTaskId()
    try testModelResourceStatusAndCompatibility()
    try testRuntimePathsModelSelectionUsesEnvironmentAndConfig()
    try testRuntimePathsModelAvailabilityAndWorkerEnvironmentUseCompleteLocalCache()
    try testModelResourcePreparerReportsMissingScriptWhenResourcesNeedPreparation()
    try testModelResourcePreparerReportsScriptFailureAndKeepsEvents()
    try testTranscriptStoreRoundTripsMetadataAndLoadsAlignmentSidecar()
    try testTranscriptStoreDecodesFractionalPythonTimestamp()
    print("Aural tests passed")
} catch {
    fail("unexpected error: \(error)")
}
