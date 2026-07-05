import Foundation

public enum TranscriptionMediaKind: String, Codable, Equatable, Sendable {
    case audio
    case video
}

public struct TranscriptionTask: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var filename: String
    public var localAudioPath: String
    public var durationSec: Double
    public var fileSizeBytes: Int64
    public var mediaKind: TranscriptionMediaKind
    public var status: TranscriptionStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var failedAt: Date?
    public var transcriptPath: String?
    public var errorLogPath: String?
    public var progressFraction: Double?

    public init(
        id: UUID = UUID(),
        filename: String,
        localAudioPath: String,
        durationSec: Double = 0,
        fileSizeBytes: Int64 = 0,
        mediaKind: TranscriptionMediaKind = .audio,
        status: TranscriptionStatus = .pending,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        failedAt: Date? = nil,
        transcriptPath: String? = nil,
        errorLogPath: String? = nil,
        progressFraction: Double? = nil
    ) {
        self.id = id
        self.filename = filename
        self.localAudioPath = localAudioPath
        self.durationSec = durationSec
        self.fileSizeBytes = fileSizeBytes
        self.mediaKind = mediaKind
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failedAt = failedAt
        self.transcriptPath = transcriptPath
        self.errorLogPath = errorLogPath
        self.progressFraction = progressFraction
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case filename
        case localAudioPath
        case durationSec
        case fileSizeBytes
        case mediaKind
        case status
        case createdAt
        case startedAt
        case completedAt
        case failedAt
        case transcriptPath
        case errorLogPath
        case progressFraction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.filename = try container.decode(String.self, forKey: .filename)
        self.localAudioPath = try container.decode(String.self, forKey: .localAudioPath)
        self.durationSec = try container.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0
        self.fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes) ?? 0
        self.mediaKind = try container.decodeIfPresent(TranscriptionMediaKind.self, forKey: .mediaKind) ?? .audio
        self.status = try container.decode(TranscriptionStatus.self, forKey: .status)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        self.failedAt = try container.decodeIfPresent(Date.self, forKey: .failedAt)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.errorLogPath = try container.decodeIfPresent(String.self, forKey: .errorLogPath)
        self.progressFraction = try container.decodeIfPresent(Double.self, forKey: .progressFraction)
    }
}
