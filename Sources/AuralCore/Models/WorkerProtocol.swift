import Foundation

public struct WorkerRequest: Codable, Equatable, Sendable {
    public var type: String
    public var requestId: UUID
    public var taskId: UUID
    public var audioPath: String
    public var outputDir: String
    public var language: String
    public var pipeline: String
    public var durationSec: Double?

    public init(
        type: String = "transcribe",
        requestId: UUID = UUID(),
        taskId: UUID,
        audioPath: String,
        outputDir: String,
        language: String = "auto",
        pipeline: String = "vad_chunked",
        durationSec: Double? = nil
    ) {
        self.type = type
        self.requestId = requestId
        self.taskId = taskId
        self.audioPath = audioPath
        self.outputDir = outputDir
        self.language = language
        self.pipeline = pipeline
        self.durationSec = durationSec
    }
}

public struct WorkerEvent: Codable, Equatable, Sendable {
    public var type: String
    public var requestId: UUID
    public var taskId: UUID
    public var stage: String?
    public var completedSegments: Int?
    public var totalSegments: Int?
    public var transcriptPath: String?
    public var durationSec: Double?
    public var errorCode: String?
    public var errorLogPath: String?

    public init(
        type: String,
        requestId: UUID,
        taskId: UUID,
        stage: String? = nil,
        completedSegments: Int? = nil,
        totalSegments: Int? = nil,
        transcriptPath: String? = nil,
        durationSec: Double? = nil,
        errorCode: String? = nil,
        errorLogPath: String? = nil
    ) {
        self.type = type
        self.requestId = requestId
        self.taskId = taskId
        self.stage = stage
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.transcriptPath = transcriptPath
        self.durationSec = durationSec
        self.errorCode = errorCode
        self.errorLogPath = errorLogPath
    }
}

public enum WorkerEventType {
    public static let progress = "progress"
    public static let completed = "completed"
    public static let failed = "failed"
}
