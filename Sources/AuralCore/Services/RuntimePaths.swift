import Foundation

public enum RuntimePaths {
    public static let alignerModelDirectoryName = "qwen3-forcedaligner-0.6b-4bit-mlx"
    public static let modelCompletionMarkerFilename = ".aural-complete.json"
    public static let modelRequiredFiles = [
        "config.json",
        "generation_config.json",
        "model.safetensors",
        "model.safetensors.index.json",
        "tokenizer_config.json",
        "vocab.json",
        "merges.txt"
    ]

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

    public static func defaultModelRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["AURAL_MODEL_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return defaultDataRoot().appendingPathComponent("Models", isDirectory: true)
    }

    public static func modelProfileConfigURL() -> URL {
        defaultDataRoot().appendingPathComponent("model-profile.json")
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

    public static func defaultModelResourcePreparerURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AURAL_MODEL_PREPARER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let resources = Bundle.main.resourceURL {
            let script = resources
                .appendingPathComponent("AuralASRWorker", isDirectory: true)
                .appendingPathComponent("model_resource_prepare.py")
            if FileManager.default.fileExists(atPath: script.path) {
                return script
            }
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return currentDirectory.appendingPathComponent("AuralASRWorker/model_resource_prepare.py")
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

    public static func requiredRuntimeIsAvailable() -> Bool {
        bundledRuntimePythonURL() != nil || ProcessInfo.processInfo.environment["AURAL_PYTHON"] != nil
    }

    public static func selectedModelProfile() -> ModelResourceProfile {
        selectedResourceConfiguration().profile
    }

    public static func selectedAlignmentEnabled() -> Bool {
        selectedResourceConfiguration().alignmentEnabled
    }

    public static func selectedResourceConfiguration() -> ModelResourceConfiguration {
        if let override = ProcessInfo.processInfo.environment["AURAL_MODEL_PROFILE"],
           let profile = ModelResourceProfile(rawValue: override) {
            let alignmentEnabled = alignmentEnabledFromEnvironment(defaultValue: true)
            return ModelResourceConfiguration(
                profile: RuntimeCompatibility.effectiveProfile(profile),
                alignmentEnabled: alignmentEnabled
            )
        }

        if let data = try? Data(contentsOf: modelProfileConfigURL()),
           let config = try? JSONDecoder().decode(ModelProfileConfig.self, from: data),
           let profile = ModelResourceProfile(rawValue: config.profile) {
            return ModelResourceConfiguration(
                profile: RuntimeCompatibility.effectiveProfile(profile),
                alignmentEnabled: config.alignmentEnabled ?? true
            )
        }

        return .default
    }

    public static func saveSelectedModelProfile(_ profile: ModelResourceProfile) throws {
        var config = selectedResourceConfiguration()
        config.profile = profile
        try saveSelectedResourceConfiguration(config)
    }

    public static func saveSelectedResourceConfiguration(_ configuration: ModelResourceConfiguration) throws {
        let effectiveProfile = RuntimeCompatibility.effectiveProfile(configuration.profile)
        try FileManager.default.createDirectory(
            at: defaultDataRoot(),
            withIntermediateDirectories: true
        )
        let config = ModelProfileConfig(
            profile: effectiveProfile.rawValue,
            alignmentEnabled: configuration.alignmentEnabled
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: modelProfileConfigURL(), options: .atomic)
    }

    public static func requiredModelsAreAvailable(profile: ModelResourceProfile = selectedModelProfile()) -> Bool {
        requiredModelsAreAvailable(
            profile: profile,
            alignmentEnabled: selectedAlignmentEnabled()
        )
    }

    public static func requiredModelsAreAvailable(
        profile: ModelResourceProfile,
        alignmentEnabled: Bool
    ) -> Bool {
        availableASRModelURL(profile: profile) != nil
            && (!alignmentEnabled || availableAlignerModelURL() != nil)
    }

    public static func requiredResourcesAreAvailable() -> Bool {
        requiredRuntimeIsAvailable() && requiredModelsAreAvailable()
    }

    public static func workerEnvironment() -> [String: String] {
        var environment: [String: String] = [
            "AURAL_MODEL_ROOT": defaultModelRoot().path,
            "AURAL_MODEL_PROFILE": selectedModelProfile().rawValue,
            "AURAL_ALIGNMENT_ENABLED": selectedAlignmentEnabled() ? "1" : "0"
        ]
        if let asrModel = availableASRModelURL(profile: selectedModelProfile()) {
            environment["AURAL_ASR_MODEL"] = asrModel.path
        }
        if selectedAlignmentEnabled(), let alignerModel = availableAlignerModelURL() {
            environment["AURAL_ALIGNER_MODEL"] = alignerModel.path
        }
        return environment
    }

    public static func availableASRModelURL(profile: ModelResourceProfile = selectedModelProfile()) -> URL? {
        let profile = RuntimeCompatibility.effectiveProfile(profile)
        if let override = ProcessInfo.processInfo.environment["AURAL_ASR_MODEL"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return modelLooksAvailable(
                url,
                minSafetensorsBytes: profile.asrMinSafetensorsBytes,
                requireCompletionMarker: false
            ) ? url : nil
        }

        let bundled = bundledASRModelURL(profile: profile)
        if let bundled, modelLooksAvailable(
            bundled,
            minSafetensorsBytes: profile.asrMinSafetensorsBytes,
            requireCompletionMarker: false
        ) {
            return bundled
        }

        let cached = defaultModelRoot().appendingPathComponent(profile.asrDirectoryName, isDirectory: true)
        return modelLooksAvailable(
            cached,
            minSafetensorsBytes: profile.asrMinSafetensorsBytes,
            requireCompletionMarker: true
        ) ? cached : nil
    }

    public static func availableAlignerModelURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["AURAL_ALIGNER_MODEL"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return modelLooksAvailable(
                url,
                minSafetensorsBytes: 500_000_000,
                requireCompletionMarker: false
            ) ? url : nil
        }

        let bundled = bundledAlignerModelURL()
        if let bundled, modelLooksAvailable(
            bundled,
            minSafetensorsBytes: 500_000_000,
            requireCompletionMarker: false
        ) {
            return bundled
        }

        let cached = defaultModelRoot().appendingPathComponent(alignerModelDirectoryName, isDirectory: true)
        return modelLooksAvailable(
            cached,
            minSafetensorsBytes: 500_000_000,
            requireCompletionMarker: true
        ) ? cached : nil
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
           bundledRuntimePythonURL() != nil {
            return segmentedWorker
        }

        if FileManager.default.fileExists(atPath: directWorker.path),
           bundledRuntimePythonURL() != nil {
            return directWorker
        }

        if FileManager.default.fileExists(atPath: qwenWorker.path),
           bundledRuntimePythonURL() != nil {
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

    public static func bundledRuntimePythonURL() -> URL? {
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

    public static func bundledASRModelURL(profile: ModelResourceProfile = selectedModelProfile()) -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }

        let model = resources.appendingPathComponent(
            "asr-models/\(RuntimeCompatibility.effectiveProfile(profile).asrDirectoryName)",
            isDirectory: true
        )
        return FileManager.default.fileExists(atPath: model.path) ? model : nil
    }

    public static func bundledAlignerModelURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }

        let model = resources.appendingPathComponent(
            "aligner-models/\(alignerModelDirectoryName)",
            isDirectory: true
        )
        return FileManager.default.fileExists(atPath: model.path) ? model : nil
    }

    private static func modelLooksAvailable(
        _ url: URL,
        minSafetensorsBytes: UInt64,
        requireCompletionMarker: Bool
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        if requireCompletionMarker,
           !FileManager.default.fileExists(
                atPath: url.appendingPathComponent(modelCompletionMarkerFilename).path
           ) {
            return false
        }

        let modelFile = url.appendingPathComponent("model.safetensors")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: modelFile.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value >= minSafetensorsBytes else {
            return false
        }

        return modelRequiredFiles.allSatisfy { filename in
            FileManager.default.fileExists(atPath: url.appendingPathComponent(filename).path)
        }
    }

    private static func alignmentEnabledFromEnvironment(defaultValue: Bool) -> Bool {
        guard let override = ProcessInfo.processInfo.environment["AURAL_ALIGNMENT_ENABLED"],
              !override.isEmpty
        else {
            return defaultValue
        }
        return ["1", "true", "yes", "on"].contains(override.lowercased())
    }
}

private struct ModelProfileConfig: Codable {
    let profile: String
    let alignmentEnabled: Bool?
}
