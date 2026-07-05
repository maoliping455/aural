import Foundation

public enum RuntimePaths {
    public static func defaultDataRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["AURAL_DATA_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        return applicationSupport.appendingPathComponent("Aural", isDirectory: true)
    }

    public static func defaultWorkerURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AURAL_WORKER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let bundled = bundledWorkerURL() {
            return bundled
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return currentDirectory.appendingPathComponent("AuralASRWorker/worker_qwen_segmented_bundle.py")
    }

    public static func defaultPythonExecutableURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AURAL_PYTHON"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let runtimePython = bundledRuntimePythonURL() {
            return runtimePython
        }

        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private static func bundledWorkerURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }

        let workerRoot = resources.appendingPathComponent("AuralASRWorker", isDirectory: true)
        let segmentedWorker = workerRoot.appendingPathComponent("worker_qwen_segmented_bundle.py")
        let directWorker = workerRoot.appendingPathComponent("worker_qwen_direct_bundle.py")
        let qwenWorker = workerRoot.appendingPathComponent("worker_qwen_bundle.py")
        let stubWorker = workerRoot.appendingPathComponent("worker_stub.py")

        if FileManager.default.fileExists(atPath: segmentedWorker.path),
           bundledRuntimePythonURL() != nil,
           bundledModelURL() != nil {
            return segmentedWorker
        }

        if FileManager.default.fileExists(atPath: directWorker.path),
           bundledRuntimePythonURL() != nil,
           bundledModelURL() != nil {
            return directWorker
        }

        if FileManager.default.fileExists(atPath: qwenWorker.path),
           bundledRuntimePythonURL() != nil,
           bundledModelURL() != nil {
            return qwenWorker
        }

        if allowsStubWorker(), FileManager.default.fileExists(atPath: stubWorker.path) {
            return stubWorker
        }

        return nil
    }

    private static func allowsStubWorker() -> Bool {
        let value = ProcessInfo.processInfo.environment["AURAL_ALLOW_STUB_WORKER"] ?? ""
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    private static func bundledRuntimePythonURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }

        let candidates = [
            resources.appendingPathComponent("runtime/bin/python3"),
            resources.appendingPathComponent("runtime/bin/python"),
            resources.appendingPathComponent("runtime/.venv/bin/python")
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func bundledModelURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }

        let model = resources.appendingPathComponent(
            "asr-models/qwen3-asr-1.7b-4bit",
            isDirectory: true
        )
        return FileManager.default.fileExists(atPath: model.path) ? model : nil
    }
}
