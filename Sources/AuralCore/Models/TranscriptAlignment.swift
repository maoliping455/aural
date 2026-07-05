import Foundation

public struct TranscriptAlignment: Codable, Equatable, Sendable {
    public var version: Int?
    public var createdAt: String?
    public var model: String?
    public var runtime: String?
    public var status: String?
    public var chunks: [TranscriptAlignmentChunk]
    public var items: [TranscriptAlignmentItem]

    public init(
        version: Int? = nil,
        createdAt: String? = nil,
        model: String? = nil,
        runtime: String? = nil,
        status: String? = nil,
        chunks: [TranscriptAlignmentChunk] = [],
        items: [TranscriptAlignmentItem] = []
    ) {
        self.version = version
        self.createdAt = createdAt
        self.model = model
        self.runtime = runtime
        self.status = status
        self.chunks = chunks
        self.items = items
    }
}

public struct TranscriptAlignmentChunk: Codable, Equatable, Sendable {
    public var index: Int
    public var startSec: Double
    public var endSec: Double
    public var language: String?
    public var status: String?
    public var alignmentItemStart: Int?
    public var alignmentItemEnd: Int?

    public init(
        index: Int,
        startSec: Double,
        endSec: Double,
        language: String? = nil,
        status: String? = nil,
        alignmentItemStart: Int? = nil,
        alignmentItemEnd: Int? = nil
    ) {
        self.index = index
        self.startSec = startSec
        self.endSec = endSec
        self.language = language
        self.status = status
        self.alignmentItemStart = alignmentItemStart
        self.alignmentItemEnd = alignmentItemEnd
    }
}

public struct TranscriptAlignmentItem: Codable, Equatable, Sendable {
    public var index: Int
    public var chunkIndex: Int
    public var text: String
    public var startSec: Double
    public var endSec: Double
    public var durationSec: Double?

    public init(
        index: Int,
        chunkIndex: Int,
        text: String,
        startSec: Double,
        endSec: Double,
        durationSec: Double? = nil
    ) {
        self.index = index
        self.chunkIndex = chunkIndex
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.durationSec = durationSec
    }
}
