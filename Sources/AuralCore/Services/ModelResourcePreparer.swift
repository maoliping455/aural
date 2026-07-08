import Foundation

public enum ModelResourcePhase: String, Codable, Equatable, Sendable {
    case checking
    case needsDownload
    case ready
    case downloading
    case failed
}

public struct ModelResourceStatus: Equatable, Sendable {
    public var phase: ModelResourcePhase
    public var title: String
    public var detail: String
    public var allowsRetry: Bool
    public var progressFraction: Double?
    public var remainingTimeText: String?

    public init(
        phase: ModelResourcePhase,
        title: String,
        detail: String,
        allowsRetry: Bool = true,
        progressFraction: Double? = nil,
        remainingTimeText: String? = nil
    ) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.allowsRetry = allowsRetry
        self.progressFraction = progressFraction
        self.remainingTimeText = remainingTimeText
    }

    public static let checking = ModelResourceStatus(
        phase: .checking,
        title: "正在检查本地转写资源",
        detail: "Aural 会优先复用已经下载到本机的资源。"
    )

    public static let ready = ModelResourceStatus(
        phase: .ready,
        title: "本地转写资源已就绪",
        detail: "可以开始在本机转写音频和视频。"
    )

    public static var needsDownload: ModelResourceStatus {
        needsDownload(configuration: .default, allowsProfileSelection: false)
    }

    public static func needsDownload(
        profile: ModelResourceProfile,
        allowsProfileSelection: Bool
    ) -> ModelResourceStatus {
        needsDownload(
            configuration: ModelResourceConfiguration(profile: profile),
            allowsProfileSelection: allowsProfileSelection
        )
    }

    public static func needsDownload(
        configuration: ModelResourceConfiguration,
        allowsProfileSelection: Bool
    ) -> ModelResourceStatus {
        let detail: String
        if allowsProfileSelection {
            detail = "选择本地转写模式和是否启用时间戳对齐。下载完成后会保存在本机，后续升级会直接复用。"
        } else {
            detail = "第一次启动需要下载\(configuration.estimatedDownloadText)本地模型。下载完成后会保存在本机，后续升级会直接复用。"
        }
        return ModelResourceStatus(
            phase: .needsDownload,
            title: "准备本地模型",
            detail: detail
        )
    }
}

public enum RuntimeCompatibility {
    public static let minimumMacOSVersion = OperatingSystemVersion(
        majorVersion: 14,
        minorVersion: 0,
        patchVersion: 0
    )

    public static func blockingStatus(
        currentVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isAppleSilicon: Bool = RuntimeMachineCapabilities.isAppleSilicon()
    ) -> ModelResourceStatus? {
        if compare(currentVersion, minimumMacOSVersion) == .orderedAscending {
            return ModelResourceStatus(
                phase: .failed,
                title: "需要 macOS 14 或更新版本",
                detail: "Aural 0.1.0 依赖 macOS 14 及以上的本地音视频处理能力。请升级系统后再使用。",
                allowsRetry: false
            )
        }

        guard isAppleSilicon else {
            return ModelResourceStatus(
                phase: .failed,
                title: "当前设备暂不支持本地转写",
                detail: "Aural 0.1.0 的本地转写资源面向 Apple Silicon Mac。Intel Mac 会在后续版本单独评估。",
                allowsRetry: false
            )
        }

        return nil
    }

    public static func supportsAccurateProfile(
        physicalMemoryBytes: UInt64 = RuntimeMachineCapabilities.physicalMemoryBytes()
    ) -> Bool {
        physicalMemoryBytes >= ModelResourceProfile.accurateMinimumMemoryBytes
    }

    public static func effectiveProfile(
        _ profile: ModelResourceProfile,
        physicalMemoryBytes: UInt64 = RuntimeMachineCapabilities.physicalMemoryBytes()
    ) -> ModelResourceProfile {
        if profile == .accurate, !supportsAccurateProfile(physicalMemoryBytes: physicalMemoryBytes) {
            return .balanced
        }
        return profile
    }

    private static func compare(
        _ lhs: OperatingSystemVersion,
        _ rhs: OperatingSystemVersion
    ) -> ComparisonResult {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion < rhs.majorVersion ? .orderedAscending : .orderedDescending
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion < rhs.minorVersion ? .orderedAscending : .orderedDescending
        }
        if lhs.patchVersion != rhs.patchVersion {
            return lhs.patchVersion < rhs.patchVersion ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

public struct ModelResourceEvent: Codable, Equatable, Sendable {
    public var type: String
    public var model: String?
    public var name: String?
    public var source: String?
    public var attempt: Int?
    public var modelId: String?
    public var path: String?
    public var message: String?
    public var modelRoot: String?
    public var profile: String?
    public var downloadedBytes: UInt64?
    public var totalBytes: UInt64?
    public var progress: Double?
}

public final class ModelResourcePreparer: @unchecked Sendable {
    public enum PreparerError: Error, Equatable {
        case runtimeUnavailable(String)
        case runtimeIncompatible(String)
        case preparerScriptUnavailable(String)
        case failed(Int32, String)
    }

    private let pythonExecutableURL: URL
    private let scriptURL: URL
    private let modelRootURL: URL
    private let profile: ModelResourceProfile
    private let alignmentEnabled: Bool
    private let fileManager: FileManager

    public init(
        profile: ModelResourceProfile = RuntimePaths.selectedModelProfile(),
        alignmentEnabled: Bool = RuntimePaths.selectedAlignmentEnabled(),
        pythonExecutableURL: URL = RuntimePaths.defaultPythonExecutableURL(),
        scriptURL: URL = RuntimePaths.defaultModelResourcePreparerURL(),
        modelRootURL: URL = RuntimePaths.defaultModelRoot(),
        fileManager: FileManager = .default
    ) {
        self.profile = RuntimeCompatibility.effectiveProfile(profile)
        self.alignmentEnabled = alignmentEnabled
        self.pythonExecutableURL = pythonExecutableURL
        self.scriptURL = scriptURL
        self.modelRootURL = modelRootURL
        self.fileManager = fileManager
    }

    public var modelRoot: URL {
        modelRootURL
    }

    public func resourcesAreReady() -> Bool {
        RuntimePaths.requiredRuntimeIsAvailable()
            && RuntimePaths.requiredModelsAreAvailable(
                profile: profile,
                alignmentEnabled: alignmentEnabled
            )
    }

    public func runtimeProbeStatus() -> ModelResourceStatus? {
        guard RuntimePaths.requiredRuntimeIsAvailable() else {
            return nil
        }

        do {
            try probeRuntimeCompatibility()
            return nil
        } catch {
            return ModelResourceStatus(
                phase: .failed,
                title: "当前系统暂不支持本地转写",
                detail: "Aural 的本地转写运行时无法在当前系统加载。请升级 macOS，或安装兼容当前系统的 Aural 版本。",
                allowsRetry: false
            )
        }
    }

    public func prepare(onEvent: @escaping @Sendable (ModelResourceEvent) -> Void) throws {
        if let runtimeStatus = runtimeProbeStatus() {
            throw PreparerError.runtimeIncompatible(runtimeStatus.detail)
        }

        if resourcesAreReady() {
            onEvent(ModelResourceEvent(type: "completed"))
            return
        }

        guard pythonExecutableURL.path != "/usr/bin/env" || commandExists("python3") else {
            throw PreparerError.runtimeUnavailable(pythonExecutableURL.path)
        }
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw PreparerError.preparerScriptUnavailable(scriptURL.path)
        }

        try fileManager.createDirectory(at: modelRootURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = pythonExecutableURL
        if pythonExecutableURL.path == "/usr/bin/env" {
            process.arguments = [
                "python3",
                scriptURL.path,
                "--model-root",
                modelRootURL.path,
                "--profile",
                profile.rawValue,
                alignmentEnabled ? "--include-aligner" : "--skip-aligner"
            ]
        } else {
            process.arguments = [
                scriptURL.path,
                "--model-root",
                modelRootURL.path,
                "--profile",
                profile.rawValue,
                alignmentEnabled ? "--include-aligner" : "--skip-aligner"
            ]
        }

        var environment = ProcessInfo.processInfo.environment
        environment["AURAL_MODEL_ROOT"] = modelRootURL.path
        environment["AURAL_MODEL_PROFILE"] = profile.rawValue
        environment["AURAL_ALIGNMENT_ENABLED"] = alignmentEnabled ? "1" : "0"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let eventReader = JSONLineEventReader(
            fileHandle: stdout.fileHandleForReading,
            onEvent: onEvent
        )
        let errorReader = DataPipeReader(fileHandle: stderr.fileHandleForReading)

        try process.run()
        eventReader.start()
        errorReader.start()
        process.waitUntilExit()
        eventReader.wait()
        let errorData = errorReader.wait()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errorData, encoding: .utf8) ?? ""
            throw PreparerError.failed(process.terminationStatus, stderrText)
        }

        if !RuntimePaths.requiredRuntimeIsAvailable()
            || !RuntimePaths.requiredModelsAreAvailable(
                profile: profile,
                alignmentEnabled: alignmentEnabled
            ) {
            throw PreparerError.failed(1, "model resources were prepared but required files are still missing")
        }
    }

    private func commandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func probeRuntimeCompatibility() throws {
        guard pythonExecutableURL.path != "/usr/bin/env" || commandExists("python3") else {
            throw PreparerError.runtimeUnavailable(pythonExecutableURL.path)
        }

        let probe = """
        import sys
        try:
            import mlx.core as mx
            value = mx.array([1.0], dtype=mx.float32)
            mx.eval(value + value)
        except Exception as exc:
            print(repr(exc), file=sys.stderr)
            raise SystemExit(70)
        """

        let process = Process()
        process.executableURL = pythonExecutableURL
        if pythonExecutableURL.path == "/usr/bin/env" {
            process.arguments = ["python3", "-c", probe]
        } else {
            process.arguments = ["-c", probe]
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw PreparerError.runtimeIncompatible(stderrText)
        }
    }
}

private final class JSONLineEventReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let onEvent: @Sendable (ModelResourceEvent) -> Void
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "io.github.maoliping455.aural.model-resource-reader")
    private let group = DispatchGroup()

    init(fileHandle: FileHandle, onEvent: @escaping @Sendable (ModelResourceEvent) -> Void) {
        self.fileHandle = fileHandle
        self.onEvent = onEvent
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func start() {
        group.enter()
        queue.async { [fileHandle, decoder, onEvent, group] in
            var buffer = ""
            while true {
                let data = fileHandle.availableData
                if data.isEmpty {
                    break
                }
                guard let chunk = String(data: data, encoding: .utf8) else {
                    continue
                }
                buffer.append(chunk)
                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[..<newlineRange.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                    guard let lineData = line.data(using: .utf8),
                          let event = try? decoder.decode(ModelResourceEvent.self, from: lineData)
                    else {
                        continue
                    }
                    onEvent(event)
                }
            }
            if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let data = buffer.data(using: .utf8),
               let event = try? decoder.decode(ModelResourceEvent.self, from: data)
            {
                onEvent(event)
            }
            group.leave()
        }
    }

    func wait() {
        group.wait()
    }
}

private final class DataPipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "io.github.maoliping455.aural.model-resource-error-reader")
    private let group = DispatchGroup()
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func start() {
        group.enter()
        queue.async { [self] in
            data = fileHandle.readDataToEndOfFile()
            group.leave()
        }
    }

    func wait() -> Data {
        group.wait()
        return data
    }
}
