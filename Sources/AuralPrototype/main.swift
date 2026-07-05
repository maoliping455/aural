import AuralCore
import Foundation

let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dataRoot = packageRoot.appendingPathComponent(".build/aural-prototype-data", isDirectory: true)
let demoAudioRoot = packageRoot.appendingPathComponent(".build/demo-audio", isDirectory: true)
let workerURL = packageRoot.appendingPathComponent("AuralASRWorker/worker_stub.py")

let fileManager = FileManager.default
try fileManager.createDirectory(at: demoAudioRoot, withIntermediateDirectories: true)

let demoAudioFiles = [
    demoAudioRoot.appendingPathComponent("产品访谈录音.m4a"),
    demoAudioRoot.appendingPathComponent("周会录音.wav"),
    demoAudioRoot.appendingPathComponent("失败样例.fail.mp3")
]

for url in demoAudioFiles {
    let marker = url.lastPathComponent.contains(".fail.") ? "aural-stub-fail" : "aural demo audio placeholder"
    try Data(marker.utf8).write(to: url)
}

if fileManager.fileExists(atPath: dataRoot.path) {
    try fileManager.removeItem(at: dataRoot)
}

let store = TaskStore(rootURL: dataRoot)
try store.bootstrap()

for audioURL in demoAudioFiles {
    _ = try store.createTask(fromAudioURL: audioURL)
}

let client = ASRWorkerClient(workerURL: workerURL)
let queue = TranscriptionQueue(store: store, workerClient: client)

do {
    _ = try queue.drainPendingTasks()
} catch {
    // A real app would keep the technical error in logs and show only "转写失败".
}

let tasks = try store.load()
for task in tasks {
    let resultPath = task.transcriptPath ?? task.errorLogPath ?? "-"
    print("\(task.filename)  \(task.status.displayName)  \(resultPath)")
}
