import Foundation

public struct Transcript: Codable, Equatable, Sendable {
    public var taskId: UUID
    public var audioDurationSec: Double
    public var createdAt: Date
    public var segments: [TranscriptSegment]
    public var text: String
    public var rawText: String?
    public var normalizedText: String?
    public var metadata: [String: JSONValue]?

    public init(
        taskId: UUID,
        audioDurationSec: Double,
        createdAt: Date = Date(),
        segments: [TranscriptSegment],
        text: String,
        rawText: String? = nil,
        normalizedText: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.taskId = taskId
        self.audioDurationSec = audioDurationSec
        self.createdAt = createdAt
        self.segments = segments
        self.text = text
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.metadata = metadata
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var startSec: Double
    public var endSec: Double
    public var text: String
    public var rawText: String?
    public var alignmentItemStart: Int?
    public var alignmentItemEnd: Int?

    public init(
        startSec: Double,
        endSec: Double,
        text: String,
        rawText: String? = nil,
        alignmentItemStart: Int? = nil,
        alignmentItemEnd: Int? = nil
    ) {
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.rawText = rawText
        self.alignmentItemStart = alignmentItemStart
        self.alignmentItemEnd = alignmentItemEnd
    }
}
