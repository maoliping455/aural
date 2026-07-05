import Foundation

public struct ProcessingRateSnapshot: Codable, Equatable, Sendable {
    public var secondsPerAudioSecond: Double
    public var updatedAt: Date

    public init(secondsPerAudioSecond: Double, updatedAt: Date = Date()) {
        self.secondsPerAudioSecond = secondsPerAudioSecond
        self.updatedAt = updatedAt
    }
}

public final class ProcessingRateStore {
    private let url: URL

    public init(rootURL: URL) {
        self.url = rootURL.appendingPathComponent("processing-rate.json")
    }

    public func load() -> ProcessingRateSnapshot? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProcessingRateSnapshot.self, from: data)
    }

    public func save(_ snapshot: ProcessingRateSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
