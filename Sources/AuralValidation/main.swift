import AuralCore
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("validation failed: \(message)\n", stderr)
        exit(1)
    }
}

func substring(_ text: String, startOffset: Int, endOffset: Int) -> String {
    let start = text.index(text.startIndex, offsetBy: startOffset)
    let end = text.index(text.startIndex, offsetBy: endOffset)
    return String(text[start..<end])
}

let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let validationRoot = packageRoot.appendingPathComponent(".build/aural-validation", isDirectory: true)
let audioRoot = validationRoot.appendingPathComponent("input", isDirectory: true)
let dataRoot = validationRoot.appendingPathComponent("data", isDirectory: true)
let workerURL = packageRoot.appendingPathComponent("AuralASRWorker/worker_stub.py")
let fileManager = FileManager.default
let validationWorkerEnvironment = ["PYTHONDONTWRITEBYTECODE": "1"]

func validationWorkerClient(
    workerURL: URL,
    timeoutSeconds: TimeInterval? = ASRWorkerClient.defaultTimeoutSeconds
) -> ASRWorkerClient {
    ASRWorkerClient(
        workerURL: workerURL,
        timeoutSeconds: timeoutSeconds,
        environment: validationWorkerEnvironment
    )
}

let oldMacOSStatus = RuntimeCompatibility.blockingStatus(
    currentVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0),
    isAppleSilicon: true
)
require(oldMacOSStatus?.allowsRetry == false, "macOS 13 should be blocked before model download")
let intelStatus = RuntimeCompatibility.blockingStatus(
    currentVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
    isAppleSilicon: false
)
require(intelStatus?.allowsRetry == false, "Intel Mac should be blocked before model download")
require(ModelResourceStatus.needsDownload.phase == .needsDownload, "missing models should be represented as a user-started download gate")
require(
    ModelResourceStatus.needsDownload(profile: .accurate, allowsProfileSelection: true).detail.contains("选择"),
    "high-memory first launch should describe local model mode selection"
)
require(
    ModelResourceConfiguration.default.profile == .balanced
        && ModelResourceConfiguration.default.alignmentEnabled,
    "default model resources should be balanced with alignment enabled"
)
require(
    ModelResourceProfile.fast.asrDirectoryName == "qwen3-asr-0.6b-4bit",
    "fast profile should use the 0.6B 4bit ASR model"
)
require(
    ModelResourceProfile.fast.isAvailable(
        physicalMemoryBytes: ModelResourceProfile.accurateMinimumMemoryBytes - 1
    ),
    "fast profile should be available below the accurate memory threshold"
)
require(
    RuntimeCompatibility.effectiveProfile(
        .accurate,
        physicalMemoryBytes: ModelResourceProfile.accurateMinimumMemoryBytes - 1
    ) == .balanced,
    "accurate profile should fall back to balanced below the memory threshold"
)
require(
    RuntimeCompatibility.effectiveProfile(
        .accurate,
        physicalMemoryBytes: ModelResourceProfile.accurateMinimumMemoryBytes
    ) == .accurate,
    "accurate profile should be available at the memory threshold"
)
let resourceEventDecoder = JSONDecoder()
resourceEventDecoder.keyDecodingStrategy = .convertFromSnakeCase
let progressEvent = try resourceEventDecoder.decode(
    ModelResourceEvent.self,
    from: Data(#"{"type":"download_progress","profile":"accurate","downloaded_bytes":123,"total_bytes":456,"progress":0.27}"#.utf8)
)
require(abs((progressEvent.progress ?? 0) - 0.27) < 0.0001, "model download progress events should decode")
require(progressEvent.downloadedBytes == 123, "model download progress should include downloaded bytes")
require(progressEvent.totalBytes == 456, "model download progress should include total bytes")
let supportedMacOSStatus = RuntimeCompatibility.blockingStatus(
    currentVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
    isAppleSilicon: true
)
require(supportedMacOSStatus == nil, "Apple Silicon macOS 14 should pass compatibility gate")

if fileManager.fileExists(atPath: validationRoot.path) {
    try fileManager.removeItem(at: validationRoot)
}

try fileManager.createDirectory(at: audioRoot, withIntermediateDirectories: true)

let okAudio = audioRoot.appendingPathComponent("ok.m4a")
let failAudio = audioRoot.appendingPathComponent("fail.mp3")
try Data("aural validation ok".utf8).write(to: okAudio)
try Data("aural-stub-fail".utf8).write(to: failAudio)

for ext in AudioFileType.supportedExtensions {
    let sampleURL = audioRoot.appendingPathComponent("supported.\(ext)")
    try Data("aural supported extension \(ext)".utf8).write(to: sampleURL)
    require(AudioFileType.isSupported(sampleURL), "extension should be supported: \(ext)")
    require(MediaFileType.isSupported(sampleURL), "audio extension should be supported as media: \(ext)")
}
require(AudioFileType.supportedContentTypes.count == AudioFileType.supportedExtensions.count, "all supported extensions should resolve to content types")

for ext in VideoFileType.supportedExtensions {
    let sampleURL = audioRoot.appendingPathComponent("supported-video.\(ext)")
    try Data("aural supported video extension \(ext)".utf8).write(to: sampleURL)
    require(VideoFileType.isSupported(sampleURL), "video extension should be supported: \(ext)")
    require(MediaFileType.isSupported(sampleURL), "video extension should be supported as media: \(ext)")
}
require(
    MediaFileType.supportedContentTypes.count == MediaFileType.supportedExtensions.count,
    "all supported media extensions should resolve to content types"
)
require(TaskStore.supportedExtensions == MediaFileType.supportedExtensionSet, "task store should expose all supported media extensions")
let unsupportedAudio = audioRoot.appendingPathComponent("unsupported.txt")
try Data("not supported".utf8).write(to: unsupportedAudio)
require(!AudioFileType.isSupported(unsupportedAudio), "txt should not be supported")
require(!MediaFileType.isSupported(unsupportedAudio), "txt should not be supported as media")

let store = TaskStore(rootURL: dataRoot)
try store.bootstrap()
let rateStore = ProcessingRateStore(rootURL: dataRoot)
try rateStore.save(ProcessingRateSnapshot(secondsPerAudioSecond: 0.12))
let loadedRate = rateStore.load()
require(abs((loadedRate?.secondsPerAudioSecond ?? 0) - 0.12) < 0.0001, "processing rate should persist")
let okTask = try store.createTask(fromAudioURL: okAudio)
let failTask = try store.createTask(fromAudioURL: failAudio)
let mediaAudioStore = TaskStore(rootURL: validationRoot.appendingPathComponent("media-audio-data", isDirectory: true))
try mediaAudioStore.bootstrap()
let mediaAudioTask = try await mediaAudioStore.createTask(fromMediaURL: okAudio)
require(mediaAudioTask.filename == okAudio.lastPathComponent, "media import should preserve audio filename")
require(mediaAudioTask.localAudioPath.hasSuffix("source.m4a"), "media import should copy audio files")
require(mediaAudioTask.mediaKind == .audio, "audio media import should keep media kind audio")

let legacyTaskJSON = """
[{
  "id": "\(UUID().uuidString)",
  "filename": "legacy.m4a",
  "localAudioPath": "\(okAudio.path)",
  "durationSec": 1,
  "fileSizeBytes": 1,
  "status": "pending",
  "createdAt": "\(ISO8601DateFormatter().string(from: Date()))"
}]
"""
let legacyTasksURL = validationRoot.appendingPathComponent("legacy-tasks.json")
try Data(legacyTaskJSON.utf8).write(to: legacyTasksURL)
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .iso8601
let legacyTasks = try legacyDecoder.decode([TranscriptionTask].self, from: Data(contentsOf: legacyTasksURL))
require(legacyTasks.first?.mediaKind == .audio, "legacy tasks should default media kind to audio")

let requestEncoder = JSONEncoder()
requestEncoder.keyEncodingStrategy = .convertToSnakeCase
let audioRequest = WorkerRequest(
    taskId: UUID(),
    audioPath: "/tmp/source.m4a",
    outputDir: "/tmp/task"
)
let audioRequestJSON = String(data: try requestEncoder.encode(audioRequest), encoding: .utf8) ?? ""
require(!audioRequestJSON.contains("video_context_"), "audio worker request should not encode video context fields")

try store.renameTask(id: okTask.id, filename: " renamed note.m4a ")
let renamedTask = try store.load().first { $0.id == okTask.id }
require(renamedTask?.filename == "renamed note.m4a", "rename should persist trimmed task filename")
try store.renameTask(id: okTask.id, filename: "   ")
let taskAfterEmptyRename = try store.load().first { $0.id == okTask.id }
require(taskAfterEmptyRename?.filename == "renamed note.m4a", "empty rename should not overwrite task filename")

let extensionStore = TaskStore(rootURL: validationRoot.appendingPathComponent("extension-data", isDirectory: true))
try extensionStore.bootstrap()
for ext in AudioFileType.supportedExtensions {
    let sampleURL = audioRoot.appendingPathComponent("supported.\(ext)")
    let task = try extensionStore.createTask(fromAudioURL: sampleURL)
    require(task.localAudioPath.hasSuffix("source.\(ext)"), "local copy should preserve extension: \(ext)")
}
let extensionTasks = try extensionStore.load()
require(extensionTasks.count == AudioFileType.supportedExtensions.count, "all supported extensions should create tasks")
do {
    _ = try extensionStore.createTask(fromAudioURL: unsupportedAudio)
    require(false, "unsupported extension should be rejected")
} catch TaskStore.StoreError.unsupportedAudioFormat(let ext) {
    require(ext == "txt", "unsupported extension should be reported")
}
let tasksAfterUnsupported = try extensionStore.load()
require(tasksAfterUnsupported.count == extensionTasks.count, "unsupported extension should not create a task")

let deleteStore = TaskStore(rootURL: validationRoot.appendingPathComponent("delete-data", isDirectory: true))
let deleteAudio = audioRoot.appendingPathComponent("delete-me.m4a")
try Data("aural validation delete".utf8).write(to: deleteAudio)
try deleteStore.bootstrap()
let deleteTask = try deleteStore.createTask(fromAudioURL: deleteAudio)
let deleteTaskDirectory = deleteStore.taskDirectoryURL(for: deleteTask.id)
let deleteTranscript = deleteTaskDirectory.appendingPathComponent("transcript.json")
try Data("{\"segments\":[]}".utf8).write(to: deleteTranscript)
require(fileManager.fileExists(atPath: deleteTask.localAudioPath), "delete task local audio copy should exist before deletion")
require(fileManager.fileExists(atPath: deleteTranscript.path), "delete task transcript should exist before deletion")
try deleteStore.deleteTask(id: deleteTask.id)
require(fileManager.fileExists(atPath: deleteAudio.path), "delete task should not remove original user file")
require(!fileManager.fileExists(atPath: deleteTaskDirectory.path), "delete task should remove app-owned task directory")
let tasksAfterDelete = try deleteStore.load()
require(tasksAfterDelete.isEmpty, "delete task should remove task record")

let queue = TranscriptionQueue(
    store: store,
    workerClient: validationWorkerClient(workerURL: workerURL)
)

let processed = try queue.drainPendingTasks()
require(processed.count == 2, "expected two processed tasks")
require(processed[0].id == okTask.id, "queue should process oldest pending task first")
require(processed[1].id == failTask.id, "queue should keep later task queued until first task finishes")

let tasks = try store.load()
let okResult = tasks.first(where: { $0.id == okTask.id })
let failResult = tasks.first(where: { $0.id == failTask.id })

require(okResult?.status == .done, "ok task should be done")
require(okResult?.transcriptPath != nil, "ok task should have transcript path")
require(okResult?.progressFraction == nil, "ok task should clear progress after completion")
require(failResult?.status == .failed, "failure task should be failed")
require(failResult?.errorLogPath != nil, "failure task should have error log path")
require(failResult?.progressFraction == nil, "failure task should clear progress after failure")

try Data("aural validation retry ok".utf8).write(to: URL(fileURLWithPath: failResult!.localAudioPath))
let restartedFailedTasks = try store.startTasks(ids: [failTask.id])
require(restartedFailedTasks.count == 1, "failed task should be restartable")
let restartedFailedTask = try store.load().first { $0.id == failTask.id }
require(restartedFailedTask?.status == .pending, "restarted failed task should return to pending")
require(restartedFailedTask?.errorLogPath == nil, "restarted failed task should clear error log path")
_ = try queue.drainPendingTasks()
let retriedFailedTask = try store.load().first { $0.id == failTask.id }
require(retriedFailedTask?.status == .done, "restarted failed task should be processed again")
require(retriedFailedTask?.transcriptPath != nil, "restarted failed task should write transcript")

let completedTask = okResult!
let transcriptURL = URL(fileURLWithPath: completedTask.transcriptPath!)
require(fileManager.fileExists(atPath: transcriptURL.path), "transcript file should exist")

let transcript = try TranscriptStore.load(from: transcriptURL)
require(transcript.segments.count >= 1, "transcript should contain timestamped segments")
require(transcript.segments[0].startSec == 0.0, "first transcript segment should start at 0")
require(transcript.rawText?.isEmpty == false, "transcript should preserve raw text")
require(transcript.normalizedText == transcript.text, "normalized transcript text should match displayed text")
require(transcript.segments[0].rawText?.isEmpty == false, "transcript segment should preserve raw text")

let invalidCompletionStore = TaskStore(
    rootURL: validationRoot.appendingPathComponent("invalid-completion-data", isDirectory: true)
)
try invalidCompletionStore.bootstrap()
let invalidCompletionAudio = audioRoot.appendingPathComponent("invalid-completion.m4a")
try Data("aural validation invalid completion".utf8).write(to: invalidCompletionAudio)
let invalidCompletionTask = try invalidCompletionStore.createTask(fromAudioURL: invalidCompletionAudio)
let invalidCompletionWorkerURL = validationRoot.appendingPathComponent("invalid_completion_worker.py")
try Data(
    """
    import json
    import sys

    request = json.loads(sys.stdin.readline())
    print(json.dumps({
        "type": "completed",
        "request_id": request["request_id"],
        "task_id": request["task_id"],
        "transcript_path": request["output_dir"] + "/missing-transcript.json",
        "duration_sec": 1
    }), flush=True)
    """.utf8
).write(to: invalidCompletionWorkerURL)
let invalidCompletionQueue = TranscriptionQueue(
    store: invalidCompletionStore,
    workerClient: validationWorkerClient(workerURL: invalidCompletionWorkerURL)
)
_ = try invalidCompletionQueue.drainPendingTasks()
let invalidCompletionResult = try invalidCompletionStore.load().first { $0.id == invalidCompletionTask.id }
require(
    invalidCompletionResult?.status == .failed,
    "completed worker event with missing transcript should be treated as failed"
)
require(
    invalidCompletionResult?.transcriptPath == nil,
    "invalid completed transcript should not be stored on task"
)
require(
    invalidCompletionResult?.errorLogPath != nil,
    "invalid completed transcript should preserve an error log"
)

let fractionalTranscriptURL = validationRoot.appendingPathComponent("fractional-created-at-transcript.json")
let fractionalTranscriptTaskId = UUID()
try Data(
    """
    {
      "task_id": "\(fractionalTranscriptTaskId.uuidString)",
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
    """.utf8
).write(to: fractionalTranscriptURL)
let fractionalTranscript = try TranscriptStore.load(from: fractionalTranscriptURL)
require(
    fractionalTranscript.taskId == fractionalTranscriptTaskId,
    "transcript store should decode Python ISO8601 dates with fractional seconds"
)

let repairInvalidDoneStore = TaskStore(
    rootURL: validationRoot.appendingPathComponent("repair-invalid-done-data", isDirectory: true)
)
try repairInvalidDoneStore.bootstrap()
let repairInvalidDoneAudio = audioRoot.appendingPathComponent("repair-invalid-done.m4a")
try Data("aural validation repair invalid done".utf8).write(to: repairInvalidDoneAudio)
var repairInvalidDoneTask = try repairInvalidDoneStore.createTask(fromAudioURL: repairInvalidDoneAudio)
repairInvalidDoneTask.status = .done
repairInvalidDoneTask.completedAt = Date()
repairInvalidDoneTask.transcriptPath = repairInvalidDoneStore
    .taskDirectoryURL(for: repairInvalidDoneTask.id)
    .appendingPathComponent("missing-transcript.json")
    .path
try repairInvalidDoneStore.update(repairInvalidDoneTask)
let repairedInvalidDoneTasks = try repairInvalidDoneStore.repairInvalidCompletedTasks()
require(repairedInvalidDoneTasks.count == 1, "repair should find invalid completed task")
let repairedInvalidDoneTask = try repairInvalidDoneStore.load().first { $0.id == repairInvalidDoneTask.id }
require(repairedInvalidDoneTask?.status == .failed, "invalid completed task should be repaired to failed")
require(repairedInvalidDoneTask?.transcriptPath == nil, "repaired invalid completed task should clear transcript path")
require(repairedInvalidDoneTask?.errorLogPath != nil, "repaired invalid completed task should write an error log")

let repairFalseFailedStore = TaskStore(
    rootURL: validationRoot.appendingPathComponent("repair-false-failed-data", isDirectory: true)
)
try repairFalseFailedStore.bootstrap()
let repairFalseFailedAudio = audioRoot.appendingPathComponent("repair-false-failed.m4a")
try Data("aural validation repair false failed".utf8).write(to: repairFalseFailedAudio)
var repairFalseFailedTask = try repairFalseFailedStore.createTask(fromAudioURL: repairFalseFailedAudio)
repairFalseFailedTask.status = .failed
repairFalseFailedTask.failedAt = Date()
repairFalseFailedTask.errorLogPath = repairFalseFailedStore
    .taskDirectoryURL(for: repairFalseFailedTask.id)
    .appendingPathComponent("error.log")
    .path
try repairFalseFailedStore.update(repairFalseFailedTask)
try TranscriptStore.save(
    Transcript(
        taskId: repairFalseFailedTask.id,
        audioDurationSec: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        segments: [TranscriptSegment(startSec: 0, endSec: 1, text: "repair false failed")],
        text: "repair false failed"
    ),
    to: repairFalseFailedStore
        .taskDirectoryURL(for: repairFalseFailedTask.id)
        .appendingPathComponent("transcript.json")
)
let repairedFalseFailedTasks = try repairFalseFailedStore.repairFailedTasksWithValidTranscript()
require(repairedFalseFailedTasks.count == 1, "repair should restore failed task when transcript is valid")
let repairedFalseFailedTask = try repairFalseFailedStore.load().first { $0.id == repairFalseFailedTask.id }
require(repairedFalseFailedTask?.status == .done, "failed task with valid transcript should be restored to done")
require(repairedFalseFailedTask?.transcriptPath?.hasSuffix("transcript.json") == true, "restored task should point to transcript")
require(repairedFalseFailedTask?.errorLogPath == nil, "restored task should clear stale error log path")

let metadataTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 42,
    segments: [TranscriptSegment(startSec: 0, endSec: 1, text: "metadata")],
    text: "metadata",
    metadata: [
        "diagnostics": .object([
            "enabled": .bool(true),
            "status": .string("ok"),
            "context_terms": .array([.string("Kodaira")]),
        ])
    ]
)
let metadataTranscriptURL = validationRoot.appendingPathComponent("metadata-transcript.json")
try TranscriptStore.save(metadataTranscript, to: metadataTranscriptURL)
let reloadedMetadataTranscript = try TranscriptStore.load(from: metadataTranscriptURL)
if case .object(let metadata)? = reloadedMetadataTranscript.metadata?["diagnostics"] {
    require(metadata["status"] == .string("ok"), "transcript metadata should preserve nested status")
} else {
    require(false, "transcript metadata should preserve diagnostics")
}

let exportTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 12,
    segments: [
        TranscriptSegment(startSec: 0, endSec: 2, text: " 第一段 "),
        TranscriptSegment(startSec: 2.5, endSec: 5, text: "  "),
        TranscriptSegment(startSec: 5, endSec: 0, text: "第二段\n换行")
    ],
    text: "fallback"
)
let plainExport = TranscriptExportRenderer.render(exportTranscript, format: .plainText)
require(plainExport == "第一段\n第二段 换行\n", "plain text export should contain displayed text without timestamps")
require(!plainExport.contains("[") && !plainExport.contains("-->"), "plain text export should not include timestamp markers")
let timestampedExport = TranscriptExportRenderer.render(exportTranscript, format: .timestampedText)
require(
    timestampedExport.contains("[00:00 - 00:02] 第一段"),
    "timestamped export should include segment start and end"
)
require(
    timestampedExport.contains("[00:05 - 00:12] 第二段 换行"),
    "timestamped export should use duration fallback for invalid segment end"
)
let srtExport = TranscriptExportRenderer.render(exportTranscript, format: .srt)
require(srtExport.contains("1\n00:00:00,000 --> 00:00:02,000\n第一段"), "SRT export should include cue number and millisecond time range")
require(srtExport.contains("\n\n2\n00:00:05,000 --> 00:00:12,000\n第二段 换行"), "SRT export should separate cues and skip empty segments")
require(TranscriptExportFormat.srt.filenameSuffix == "-字幕", "SRT export suffix should match product copy")
require(TranscriptExportFormat.plainText.filenameSuffix == "-转写", "plain text export suffix should match product copy")
require(TranscriptExportFormat.timestampedText.filenameSuffix == "-分段时间", "timestamped export suffix should match product copy")

let repeatedSentence = "为何会觉得此人有些熟悉？"
let noisyTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 120,
    segments: [
        TranscriptSegment(startSec: 0, endSec: 10, text: "前置内容。"),
        TranscriptSegment(startSec: 10, endSec: 20, text: String(repeating: repeatedSentence, count: 5)),
        TranscriptSegment(startSec: 20, endSec: 20, text: repeatedSentence),
        TranscriptSegment(startSec: 20, endSec: 20, text: repeatedSentence),
        TranscriptSegment(startSec: 20, endSec: 20, text: repeatedSentence),
        TranscriptSegment(startSec: 30, endSec: 40, text: "后续内容。")
    ],
    text: "前置内容。" + String(repeating: repeatedSentence, count: 8) + "后续内容。",
    rawText: String(repeating: repeatedSentence, count: 8),
    normalizedText: String(repeating: repeatedSentence, count: 8)
)
let cleanedTranscript = TranscriptCleanup.removingExcessiveRepetition(from: noisyTranscript)
let repeatedCount = cleanedTranscript.text.components(separatedBy: repeatedSentence).count - 1
require(repeatedCount == 1, "transcript cleanup should collapse excessive repeated sentences")
require(cleanedTranscript.segments.count == 3, "transcript cleanup should collapse repeated segments")

let orphanLatinTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 60,
    segments: [
        TranscriptSegment(
            startSec: 37.337,
            endSec: 44.643,
            text: "a normal computer like a CPU can't possibly be the right format. And so we imagined that there would be a way to accelerate the CP"
        ),
        TranscriptSegment(startSec: 44.643, endSec: 44.774, text: "U,"),
        TranscriptSegment(
            startSec: 44.774,
            endSec: 51.57,
            text: "offload the work that is not suitable for general-purpose things."
        )
    ],
    text: ""
)
let orphanCleanedTranscript = TranscriptCleanup.removingExcessiveRepetition(from: orphanLatinTranscript)
require(orphanCleanedTranscript.segments.count == 2, "transcript cleanup should merge orphan latin fragments")
require(orphanCleanedTranscript.segments[0].text.contains("CPU,"), "transcript cleanup should restore split latin word")

let spacedAcronymTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 10,
    segments: [
        TranscriptSegment(startSec: 0, endSec: 4, text: "我觉得这个O K的，A I能力也可以。"),
        TranscriptSegment(startSec: 4, endSec: 8, text: "A B测试和C P U都需要合并。"),
        TranscriptSegment(startSec: 8, endSec: 10, text: "不要影响ABCword这种正常英文边界。")
    ],
    text: ""
)
let spacedAcronymCleaned = TranscriptCleanup.removingExcessiveRepetition(from: spacedAcronymTranscript)
require(spacedAcronymCleaned.segments[0].text.contains("OK的，AI能力"), "transcript cleanup should merge common spaced acronyms")
require(spacedAcronymCleaned.segments[1].text.contains("AB测试和CPU"), "transcript cleanup should merge generic uppercase letter acronyms")
require(spacedAcronymCleaned.segments[2].text.contains("ABCword"), "transcript cleanup should not alter normal English boundaries")

let briefConnectorTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 120,
    segments: [
        TranscriptSegment(
            startSec: 0,
            endSec: 6.4,
            text: "General-purpose computing.Everything was about CPUs.Everything was about Moore's law."
        ),
        TranscriptSegment(
            startSec: 6.4,
            endSec: 11.76,
            text: "were two simultaneous ideas that Chris Kurz and I were considering. And one idea,"
        ),
        TranscriptSegment(startSec: 11.76, endSec: 12.24, text: "of course,"),
        TranscriptSegment(
            startSec: 12.72,
            endSec: 20.16,
            text: "is every application that's interesting and meaningful can it be run on a CPU?"
        ),
        TranscriptSegment(
            startSec: 33.2,
            endSec: 35.36,
            text: "or simulation,or other things beyond that,"
        )
    ],
    text: ""
)
let briefConnectorCleaned = TranscriptCleanup.removingExcessiveRepetition(from: briefConnectorTranscript)
require(briefConnectorCleaned.segments.count == 4, "transcript cleanup should merge brief latin connector segments")
require(
    briefConnectorCleaned.segments[0].text.contains("computing. Everything"),
    "transcript cleanup should add missing english sentence spacing"
)
require(
    briefConnectorCleaned.segments[1].text.contains("And one idea, of course,"),
    "transcript cleanup should fold brief connector into adjacent latin segment"
)
require(
    !briefConnectorCleaned.segments.contains(where: { $0.text == "of course," }),
    "transcript cleanup should not leave brief latin connector alone"
)
require(
    briefConnectorCleaned.segments[3].text.contains("simulation, or other"),
    "transcript cleanup should add missing english comma spacing"
)

let asrTemplateLeakTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 120,
    segments: [
        TranscriptSegment(
            startSec: 0,
            endSec: 9.52,
            text: "language Chinese<asr_text>好像有点难易度颠倒了，那我就按照先易后难。"
        ),
        TranscriptSegment(
            startSec: 9.92,
            endSec: 22.08,
            text: "所以有时某些章节的内容会有一些小的颠倒在顺序上。"
        )
    ],
    text: ""
)
let asrTemplateLeakCleaned = TranscriptCleanup.removingExcessiveRepetition(from: asrTemplateLeakTranscript)
require(
    asrTemplateLeakCleaned.segments[0].text == "好像有点难易度颠倒了，那我就按照先易后难。",
    "transcript cleanup should strip leaked ASR template prefix"
)
require(
    !asrTemplateLeakCleaned.text.contains("<asr_text>") && !asrTemplateLeakCleaned.text.contains("language Chinese"),
    "transcript cleanup should remove ASR template markers from display text"
)

let playbackText = "苏州的coffee chat的分享，然后日常的工作是对接150多家企业。U.S. market is ready, next step."
let playbackSlices = TranscriptPlaybackSlicer.slices(in: playbackText)
require(
    playbackSlices.map(\.text) == [
        "苏州的coffee chat的分享，",
        "然后日常的工作是对接150多家企业。",
        "U.S. market is ready,",
        " next step."
    ],
    "playback slicer should use punctuation units without splitting abbreviation dots"
)
let playbackSegment = TranscriptSegment(startSec: 0, endSec: 20, text: playbackText)
let sentenceHighlight = TranscriptPlaybackSlicer.activeHighlight(in: playbackSegment, at: 7.5)
require(
    sentenceHighlight?.text == "然后日常的工作是对接150多家企业。",
    "playback highlight should stay within the active punctuation unit"
)
if let sentenceHighlight {
    let highlighted = substring(
        playbackText,
        startOffset: sentenceHighlight.sliceStartOffset,
        endOffset: sentenceHighlight.highlightEndOffset
    )
    require(
        highlighted.hasPrefix("然后"),
        "playback highlight should progress from the active unit start"
    )
    require(
        !highlighted.contains("苏州的"),
        "playback highlight should not include previous punctuation units"
    )
} else {
    require(false, "playback highlight should exist for active segment")
}

let alignedPlaybackSegment = TranscriptSegment(
    startSec: 0,
    endSec: 4,
    text: "你好，世界。",
    alignmentItemStart: 0,
    alignmentItemEnd: 4
)
let exactHighlight = TranscriptPlaybackSlicer.activeHighlight(
    in: alignedPlaybackSegment,
    at: 2.2,
    alignmentItems: [
        TranscriptAlignmentItem(index: 0, chunkIndex: 1, text: "你", startSec: 0.0, endSec: 0.4, durationSec: 0.4),
        TranscriptAlignmentItem(index: 1, chunkIndex: 1, text: "好", startSec: 0.4, endSec: 0.8, durationSec: 0.4),
        TranscriptAlignmentItem(index: 2, chunkIndex: 1, text: "世", startSec: 2.0, endSec: 2.4, durationSec: 0.4),
        TranscriptAlignmentItem(index: 3, chunkIndex: 1, text: "界", startSec: 2.4, endSec: 2.8, durationSec: 0.4),
    ]
)
require(exactHighlight?.text == "世界。", "exact playback highlight should use punctuation unit boundary")
if let exactHighlight {
    let highlighted = substring(
        alignedPlaybackSegment.text,
        startOffset: exactHighlight.sliceStartOffset,
        endOffset: exactHighlight.highlightEndOffset
    )
    require(highlighted == "世", "exact playback highlight should advance by aligned item timing")
} else {
    require(false, "exact playback highlight should exist")
}
let exactSeekTime = TranscriptPlaybackSlicer.seekTime(
    in: alignedPlaybackSegment,
    atTextOffset: 3,
    alignmentItems: [
        TranscriptAlignmentItem(index: 0, chunkIndex: 1, text: "你", startSec: 0.0, endSec: 0.4, durationSec: 0.4),
        TranscriptAlignmentItem(index: 1, chunkIndex: 1, text: "好", startSec: 0.4, endSec: 0.8, durationSec: 0.4),
        TranscriptAlignmentItem(index: 2, chunkIndex: 1, text: "世", startSec: 2.0, endSec: 2.4, durationSec: 0.4),
        TranscriptAlignmentItem(index: 3, chunkIndex: 1, text: "界", startSec: 2.4, endSec: 2.8, durationSec: 0.4),
    ]
)
require(abs(exactSeekTime - 2.0) < 0.0001, "double-click seek should prefer exact alignment item time")
let estimatedSeekSegment = TranscriptSegment(startSec: 10, endSec: 22, text: "abcdef")
let estimatedSeekTime = TranscriptPlaybackSlicer.seekTime(
    in: estimatedSeekSegment,
    atTextOffset: 3,
    alignmentItems: []
)
require(abs(estimatedSeekTime - 16.0) < 0.0001, "double-click seek should estimate by text offset without alignment")
require(
    TranscriptPlaybackSlicer.activeHighlight(
        in: alignedPlaybackSegment,
        at: -0.1,
        alignmentItems: [
            TranscriptAlignmentItem(index: 0, chunkIndex: 1, text: "你", startSec: 0.0, endSec: 0.4, durationSec: 0.4)
        ]
    ) == nil,
    "exact playback highlight should not show future text before segment starts"
)
require(
    TranscriptPlaybackSlicer.activeHighlight(in: alignedPlaybackSegment, at: -0.1) == nil,
    "estimated playback highlight should not show future text before segment starts"
)

let alignmentTranscript = Transcript(
    taskId: UUID(),
    audioDurationSec: 4,
    segments: [alignedPlaybackSegment],
    text: alignedPlaybackSegment.text
)
let alignmentTranscriptURL = validationRoot.appendingPathComponent("alignment-transcript.json")
try TranscriptStore.save(alignmentTranscript, to: alignmentTranscriptURL)
let alignmentSidecarURL = validationRoot.appendingPathComponent("alignment.json")
try Data(
    """
    {
      "version": 1,
      "status": "ok",
      "chunks": [],
      "items": [
        {"index": 0, "chunk_index": 1, "text": "你", "start_sec": 0.0, "end_sec": 0.4, "duration_sec": 0.4}
      ]
    }
    """.utf8
).write(to: alignmentSidecarURL)
let loadedAlignmentTranscript = try TranscriptStore.load(from: alignmentTranscriptURL)
let loadedAlignment = try TranscriptStore.loadAlignment(forTranscriptAt: alignmentTranscriptURL)
require(loadedAlignmentTranscript.segments[0].alignmentItemStart == 0, "transcript should decode alignment item start")
require(loadedAlignmentTranscript.segments[0].alignmentItemEnd == 4, "transcript should decode alignment item end")
require(loadedAlignment?.items.first?.text == "你", "transcript store should load alignment sidecar")

require(TranscriptionStatus.pending.displayName == "未开始", "pending display name")
require(TranscriptionStatus.running.displayName == "转写中", "running display name")
require(TranscriptionStatus.paused.displayName == "已停止", "paused display name")
require(TranscriptionStatus.done.displayName == "转写完成", "done display name")
require(TranscriptionStatus.failed.displayName == "转写失败", "failed display name")

let pauseStore = TaskStore(rootURL: validationRoot.appendingPathComponent("pause-data", isDirectory: true))
let pauseAudio = audioRoot.appendingPathComponent("pause-me.m4a")
let pauseQueueAudio = audioRoot.appendingPathComponent("pause-queue.m4a")
try Data("aural validation pause".utf8).write(to: pauseAudio)
try Data("aural validation pause queue".utf8).write(to: pauseQueueAudio)
try pauseStore.bootstrap()
let pausedTask = try pauseStore.createTask(fromAudioURL: pauseAudio)
let pauseQueueTask = try pauseStore.createTask(fromAudioURL: pauseQueueAudio)
try pauseStore.pauseTasks(ids: [pausedTask.id])
let tasksAfterPause = try pauseStore.load()
require(tasksAfterPause.first(where: { $0.id == pausedTask.id })?.status == .paused, "pause should mark task paused")
let pauseQueue = TranscriptionQueue(
    store: pauseStore,
    workerClient: validationWorkerClient(workerURL: workerURL)
)
_ = try pauseQueue.drainPendingTasks()
let tasksAfterPauseDrain = try pauseStore.load()
require(tasksAfterPauseDrain.first(where: { $0.id == pausedTask.id })?.status == .paused, "paused task should stay out of queue")
require(tasksAfterPauseDrain.first(where: { $0.id == pauseQueueTask.id })?.status == .done, "other pending task should continue")
try pauseStore.resumeTasks(ids: [pausedTask.id])
let tasksAfterResume = try pauseStore.load()
require(tasksAfterResume.first(where: { $0.id == pausedTask.id })?.status == .pending, "resume should return task to pending")
_ = try pauseQueue.drainPendingTasks()
let resumedTasks = try pauseStore.load()
require(resumedTasks.first(where: { $0.id == pausedTask.id })?.status == .done, "resumed task should complete")

var interruptedTask = TranscriptionTask(
    id: UUID(),
    filename: "interrupted.wav",
    localAudioPath: dataRoot.appendingPathComponent("tasks/interrupted/source.wav").path,
    durationSec: 3,
    fileSizeBytes: 12,
    status: .running,
    createdAt: Date(),
    startedAt: Date(),
    transcriptPath: dataRoot.appendingPathComponent("tasks/interrupted/transcript.json").path,
    errorLogPath: dataRoot.appendingPathComponent("tasks/interrupted/error.log").path,
    progressFraction: 0.42
)
var alreadyDoneTask = TranscriptionTask(
    filename: "done.wav",
    localAudioPath: dataRoot.appendingPathComponent("tasks/done/source.wav").path,
    status: .done
)
let recoveryStore = TaskStore(rootURL: validationRoot.appendingPathComponent("recovery-data", isDirectory: true))
try recoveryStore.bootstrap()
try recoveryStore.save([interruptedTask, alreadyDoneTask])
let recoveredTasks = try recoveryStore.recoverInterruptedTasks()
let recoveredStoreTasks = try recoveryStore.load()
let recoveredInterrupted = recoveredStoreTasks.first(where: { $0.id == interruptedTask.id })
let recoveredDone = recoveredStoreTasks.first(where: { $0.id == alreadyDoneTask.id })
require(recoveredTasks.count == 1, "only running tasks should be recovered")
require(recoveredInterrupted?.status == .pending, "interrupted running task should return to pending")
require(recoveredInterrupted?.startedAt == nil, "recovered task should clear startedAt")
require(recoveredInterrupted?.transcriptPath == nil, "recovered task should clear stale transcript path")
require(recoveredInterrupted?.errorLogPath == nil, "recovered task should clear stale error log path")
require(recoveredInterrupted?.progressFraction == nil, "recovered task should clear stale progress")
require(recoveredDone?.status == .done, "done task should not be changed by recovery")

let recoverQueueRoot = validationRoot.appendingPathComponent("recover-queue", isDirectory: true)
let recoverQueueAudioRoot = recoverQueueRoot.appendingPathComponent("input", isDirectory: true)
let recoverQueueDataRoot = recoverQueueRoot.appendingPathComponent("data", isDirectory: true)
try fileManager.createDirectory(at: recoverQueueAudioRoot, withIntermediateDirectories: true)
let recoverQueueAudio = recoverQueueAudioRoot.appendingPathComponent("resume.m4a")
try Data("aural validation recovery queue".utf8).write(to: recoverQueueAudio)

let recoverQueueStore = TaskStore(rootURL: recoverQueueDataRoot)
try recoverQueueStore.bootstrap()
var recoverQueueTask = try recoverQueueStore.createTask(fromAudioURL: recoverQueueAudio)
recoverQueueTask.status = .running
recoverQueueTask.startedAt = Date()
try recoverQueueStore.update(recoverQueueTask)
_ = try recoverQueueStore.recoverInterruptedTasks()
let recoverQueue = TranscriptionQueue(
    store: recoverQueueStore,
    workerClient: validationWorkerClient(workerURL: workerURL)
)
_ = try recoverQueue.drainPendingTasks()
let recoverQueueTasks = try recoverQueueStore.load()
let recoveredCompletedTask = recoverQueueTasks.first(where: { $0.id == recoverQueueTask.id })
require(recoveredCompletedTask?.status == .done, "recovered queue task should complete")
require(recoveredCompletedTask?.transcriptPath != nil, "recovered queue task should have transcript path")

let crashValidationRoot = validationRoot.appendingPathComponent("crash-worker", isDirectory: true)
let crashAudioRoot = crashValidationRoot.appendingPathComponent("input", isDirectory: true)
let crashDataRoot = crashValidationRoot.appendingPathComponent("data", isDirectory: true)
try fileManager.createDirectory(at: crashAudioRoot, withIntermediateDirectories: true)

let crashWorker = crashValidationRoot.appendingPathComponent("worker_stderr_exit.py")
try Data(
    """
    #!/usr/bin/env python3
    import sys
    sys.stderr.write("worker diagnostic before exit\\n")
    sys.exit(2)
    """.utf8
).write(to: crashWorker)

let crashAudio = crashAudioRoot.appendingPathComponent("bad.wav")
try Data("not a real wav".utf8).write(to: crashAudio)

let crashStore = TaskStore(rootURL: crashDataRoot)
try crashStore.bootstrap()
let crashTask = try crashStore.createTask(fromAudioURL: crashAudio)
let crashQueue = TranscriptionQueue(
    store: crashStore,
    workerClient: validationWorkerClient(workerURL: crashWorker)
)

do {
    _ = try crashQueue.drainPendingTasks()
    require(false, "crash worker should throw")
} catch {
    let crashTasks = try crashStore.load()
    let failedTask = crashTasks.first(where: { $0.id == crashTask.id })
    require(failedTask?.status == .failed, "crash worker task should be failed")
    require(failedTask?.errorLogPath != nil, "crash worker failure should have error log path")
    let errorLogPath = failedTask!.errorLogPath!
    require(fileManager.fileExists(atPath: errorLogPath), "crash worker error log should exist")
    let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
    require(errorLog.contains("worker diagnostic before exit"), "stderr should be captured in error log")
    require(errorLog.contains("worker exited with status 2"), "exit status should be captured in error log")
}

let missingEventRoot = validationRoot.appendingPathComponent("missing-terminal-event", isDirectory: true)
let missingEventAudioRoot = missingEventRoot.appendingPathComponent("input", isDirectory: true)
let missingEventDataRoot = missingEventRoot.appendingPathComponent("data", isDirectory: true)
try fileManager.createDirectory(at: missingEventAudioRoot, withIntermediateDirectories: true)

let missingEventWorker = missingEventRoot.appendingPathComponent("worker_missing_event.py")
try Data(
    """
    #!/usr/bin/env python3
    import json
    import sys
    for line in sys.stdin:
        request = json.loads(line)
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 0,
            "total_segments": 1
        }), flush=True)
    """.utf8
).write(to: missingEventWorker)

let missingEventAudio = missingEventAudioRoot.appendingPathComponent("missing.wav")
try Data("valid enough for store".utf8).write(to: missingEventAudio)

let missingEventStore = TaskStore(rootURL: missingEventDataRoot)
try missingEventStore.bootstrap()
let missingEventTask = try missingEventStore.createTask(fromAudioURL: missingEventAudio)
let missingEventQueue = TranscriptionQueue(
    store: missingEventStore,
    workerClient: validationWorkerClient(workerURL: missingEventWorker)
)

do {
    _ = try missingEventQueue.drainPendingTasks()
    require(false, "worker without terminal event should throw")
} catch {
    let missingEventTasks = try missingEventStore.load()
    let failedTask = missingEventTasks.first(where: { $0.id == missingEventTask.id })
    require(failedTask?.status == .failed, "missing terminal event task should be failed")
    require(failedTask?.errorLogPath != nil, "missing terminal event should have fallback error log path")
    let errorLogPath = failedTask!.errorLogPath!
    require(fileManager.fileExists(atPath: errorLogPath), "missing terminal event fallback error log should exist")
    let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
    require(errorLog.contains("missingCompletionEvent"), "fallback error log should describe missing completion event")
}

let timeoutRoot = validationRoot.appendingPathComponent("timeout-worker", isDirectory: true)
let timeoutAudioRoot = timeoutRoot.appendingPathComponent("input", isDirectory: true)
let timeoutDataRoot = timeoutRoot.appendingPathComponent("data", isDirectory: true)
try fileManager.createDirectory(at: timeoutAudioRoot, withIntermediateDirectories: true)

let timeoutWorker = timeoutRoot.appendingPathComponent("worker_timeout.py")
try Data(
    """
    #!/usr/bin/env python3
    import json
    import sys
    import time
    for line in sys.stdin:
        request = json.loads(line)
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 0,
            "total_segments": 1
        }), flush=True)
        time.sleep(10)
    """.utf8
).write(to: timeoutWorker)

let timeoutAudio = timeoutAudioRoot.appendingPathComponent("timeout.wav")
try Data("valid enough for store".utf8).write(to: timeoutAudio)

let timeoutStore = TaskStore(rootURL: timeoutDataRoot)
try timeoutStore.bootstrap()
let timeoutTask = try timeoutStore.createTask(fromAudioURL: timeoutAudio)
let timeoutQueue = TranscriptionQueue(
    store: timeoutStore,
    workerClient: validationWorkerClient(workerURL: timeoutWorker, timeoutSeconds: 0.2)
)

do {
    _ = try timeoutQueue.drainPendingTasks()
    require(false, "timed out worker should throw")
} catch ASRWorkerClient.ClientError.workerTimedOut {
    let timeoutTasks = try timeoutStore.load()
    let failedTask = timeoutTasks.first(where: { $0.id == timeoutTask.id })
    require(failedTask?.status == .failed, "timed out worker task should be failed")
    require(failedTask?.errorLogPath != nil, "timed out worker should have error log path")
    let errorLogPath = failedTask!.errorLogPath!
    require(fileManager.fileExists(atPath: errorLogPath), "timed out worker error log should exist")
    let errorLog = try String(contentsOfFile: errorLogPath, encoding: .utf8)
    require(errorLog.contains("worker timed out"), "timeout should be captured in error log")
}

let cancelledRoot = validationRoot.appendingPathComponent("cancelled-worker", isDirectory: true)
let cancelledAudioRoot = cancelledRoot.appendingPathComponent("input", isDirectory: true)
let cancelledDataRoot = cancelledRoot.appendingPathComponent("data", isDirectory: true)
try fileManager.createDirectory(at: cancelledAudioRoot, withIntermediateDirectories: true)

let cancelledWorker = cancelledRoot.appendingPathComponent("worker_cancelled.py")
try Data(
    """
    #!/usr/bin/env python3
    import json
    import sys
    import time
    for line in sys.stdin:
        request = json.loads(line)
        print(json.dumps({
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 0,
            "total_segments": 1
        }), flush=True)
        time.sleep(10)
    """.utf8
).write(to: cancelledWorker)

let cancelledAudio = cancelledAudioRoot.appendingPathComponent("cancel.wav")
try Data("valid enough for cancellation".utf8).write(to: cancelledAudio)

let cancelledStore = TaskStore(rootURL: cancelledDataRoot)
try cancelledStore.bootstrap()
let cancelledTask = try cancelledStore.createTask(fromAudioURL: cancelledAudio)
let cancelledClient = validationWorkerClient(workerURL: cancelledWorker, timeoutSeconds: 5)

do {
    _ = try cancelledClient.transcribe(
        task: cancelledTask,
        outputDir: cancelledStore.taskDirectoryURL(for: cancelledTask.id),
        shouldCancel: { true }
    )
    require(false, "cancelled worker should throw cancelled")
} catch ASRWorkerClient.ClientError.cancelled(let taskId) {
    require(taskId == cancelledTask.id, "cancelled worker should report task id")
}

print("Aural validation passed")
