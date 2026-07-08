import Darwin
import Foundation

public enum ModelResourceProfile: String, Codable, CaseIterable, Equatable, Sendable {
    case fast
    case balanced
    case accurate

    public static let accurateMinimumMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    public var displayName: String {
        switch self {
        case .fast:
            return "极速"
        case .balanced:
            return "平衡"
        case .accurate:
            return "精准"
        }
    }

    public var shortDescription: String {
        switch self {
        case .fast:
            return "更快完成，资源占用更低"
        case .balanced:
            return "推荐，平衡速度和准确性"
        case .accurate:
            return "更追求准确性，占用更高"
        }
    }

    public var estimatedDownloadText: String {
        "\(estimatedASRDownloadGBText)"
    }

    public var estimatedASRDownloadGBText: String {
        switch self {
        case .fast:
            return "约 0.8GB"
        case .balanced:
            return "约 1.6GB"
        case .accurate:
            return "约 4.1GB"
        }
    }

    public var asrDirectoryName: String {
        switch self {
        case .fast:
            return "qwen3-asr-0.6b-4bit"
        case .balanced:
            return "qwen3-asr-1.7b-4bit"
        case .accurate:
            return "qwen3-asr-1.7b-bf16"
        }
    }

    public var asrMinSafetensorsBytes: UInt64 {
        switch self {
        case .fast:
            return 500_000_000
        case .balanced:
            return 1_000_000_000
        case .accurate:
            return 3_000_000_000
        }
    }

    public func isAvailable(
        physicalMemoryBytes: UInt64 = RuntimeMachineCapabilities.physicalMemoryBytes()
    ) -> Bool {
        switch self {
        case .fast, .balanced:
            return true
        case .accurate:
            return physicalMemoryBytes >= Self.accurateMinimumMemoryBytes
        }
    }
}

public struct ModelResourceConfiguration: Codable, Equatable, Sendable {
    public var profile: ModelResourceProfile
    public var alignmentEnabled: Bool

    public init(
        profile: ModelResourceProfile = .balanced,
        alignmentEnabled: Bool = true
    ) {
        self.profile = profile
        self.alignmentEnabled = alignmentEnabled
    }

    public static let `default` = ModelResourceConfiguration()

    public var estimatedDownloadText: String {
        let bytes = profile.asrEstimatedBytes + (alignmentEnabled ? Self.alignerEstimatedBytes : 0)
        return "约 \(Self.formatGB(bytes))"
    }

    public static let alignerEstimatedBytes: UInt64 = 1_000_000_000

    private static func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb < 1 {
            return String(format: "%.1fGB", gb)
        }
        return String(format: "%.1fGB", gb)
            .replacingOccurrences(of: ".0GB", with: "GB")
    }
}

extension ModelResourceProfile {
    public var asrEstimatedBytes: UInt64 {
        switch self {
        case .fast:
            return 760_000_000
        case .balanced:
            return 1_610_000_000
        case .accurate:
            return 4_080_000_000
        }
    }
}

public enum RuntimeMachineCapabilities {
    public static func isAppleSilicon() -> Bool {
        if let override = ProcessInfo.processInfo.environment["AURAL_FORCE_APPLE_SILICON"] {
            return ["1", "true", "yes"].contains(override.lowercased())
        }

        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    public static func physicalMemoryBytes() -> UInt64 {
        if let override = ProcessInfo.processInfo.environment["AURAL_FORCE_MEMORY_BYTES"],
           let value = UInt64(override) {
            return value
        }

        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &value, &size, nil, 0)
        if result == 0, value > 0 {
            return value
        }

        return ProcessInfo.processInfo.physicalMemory
    }
}
