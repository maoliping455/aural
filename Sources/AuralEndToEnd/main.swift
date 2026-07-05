import AuralCore
import Foundation

struct Arguments {
    var dataRoot: URL?
    var worker: URL?
    var python: URL?
    var audio: URL?
    var expectedStatus: TranscriptionStatus = .done
}

func fail(_ message: String) -> Never {
    fputs("aural-e2e failed: \(message)\n", stderr)
    exit(1)
}

func parseArguments(_ raw: [String]) -> Arguments {
    var arguments = Arguments()
    var index = 1
    while index < raw.count {
        switch raw[index] {
        case "--data-root":
            index += 1
            guard index < raw.count else { fail("--data-root requires a path") }
            arguments.dataRoot = URL(fileURLWithPath: raw[index])
        case "--worker":
            index += 1
            guard index < raw.count else { fail("--worker requires a path") }
            arguments.worker = URL(fileURLWithPath: raw[index])
        case "--python":
            index += 1
            guard index < raw.count else { fail("--python requires a path") }
            arguments.python = URL(fileURLWithPath: raw[index])
        case "--expect":
            index += 1
            guard index < raw.count else { fail("--expect requires done or failed") }
            switch raw[index] {
            case "done":
                arguments.expectedStatus = .done
            case "failed":
                arguments.expectedStatus = .failed
            default:
                fail("--expect must be done or failed")
            }
        default:
            if arguments.audio == nil {
                arguments.audio = URL(fileURLWithPath: raw[index])
            } else {
                fail("unexpected argument: \(raw[index])")
            }
        }
        index += 1
    }
    return arguments
}

let arguments = parseArguments(CommandLine.arguments)
let dataRoot = arguments.dataRoot ?? URL(fileURLWithPath: ".build/aural-e2e-data", isDirectory: true)
guard let worker = arguments.worker else {
    fail("--worker is required")
}
guard let python = arguments.python else {
    fail("--python is required")
}
guard let audio = arguments.audio else {
    fail("audio path is required")
}

let fileManager = FileManager.default
if fileManager.fileExists(atPath: dataRoot.path) {
    try fileManager.removeItem(at: dataRoot)
}

let store = TaskStore(rootURL: dataRoot)
try store.bootstrap()
let task = try store.createTask(fromAudioURL: audio)
let copiedAudioURL = URL(fileURLWithPath: task.localAudioPath)
guard FileManager.default.fileExists(atPath: copiedAudioURL.path) else {
    fail("local audio copy missing")
}
guard copiedAudioURL.standardizedFileURL.path != audio.standardizedFileURL.path else {
    fail("task must use an app-owned audio copy, not the original file")
}
guard copiedAudioURL.standardizedFileURL.path.hasPrefix(dataRoot.standardizedFileURL.path) else {
    fail("local audio copy should be stored under data root")
}

let queue = TranscriptionQueue(
    store: store,
    workerClient: ASRWorkerClient(workerURL: worker, pythonExecutableURL: python)
)

_ = try queue.drainPendingTasks()

let tasks = try store.load()
guard let result = tasks.first(where: { $0.id == task.id }) else {
    fail("task missing after queue run")
}

guard result.status == arguments.expectedStatus else {
    fail("expected \(arguments.expectedStatus.rawValue) status, got \(result.status.rawValue)")
}

print("task_id=\(result.id.uuidString)")
print("status=\(result.status.displayName)")
print("duration=\(String(format: "%.3f", result.durationSec))")
print("local_audio=\(result.localAudioPath)")

switch arguments.expectedStatus {
case .done:
    guard let transcriptPath = result.transcriptPath else {
        fail("completed task missing transcript path")
    }
    guard transcriptPath.hasPrefix(dataRoot.standardizedFileURL.path) else {
        fail("transcript should be stored under data root")
    }

    let transcript = try TranscriptStore.load(from: URL(fileURLWithPath: transcriptPath))
    guard !transcript.segments.isEmpty else {
        fail("transcript has no segments")
    }
    guard transcript.segments[0].startSec == 0 else {
        fail("first segment must start at 0")
    }
    guard transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        fail("transcript text is empty")
    }
    print("segments=\(transcript.segments.count)")
    print("transcript=\(transcriptPath)")
case .failed:
    guard result.transcriptPath == nil else {
        fail("failed task should not have transcript path")
    }
    guard let errorLogPath = result.errorLogPath else {
        fail("failed task missing error log path")
    }
    guard errorLogPath.hasPrefix(dataRoot.standardizedFileURL.path) else {
        fail("error log should be stored under data root")
    }
    guard FileManager.default.fileExists(atPath: errorLogPath) else {
        fail("error log does not exist")
    }
    print("error_log=\(errorLogPath)")
case .pending, .running, .paused:
    fail("unsupported expected terminal status")
}
