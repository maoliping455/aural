import Foundation

public enum TranscriptStore {
    public static func load(from url: URL) throws -> Transcript {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            try decodeDate(from: decoder)
        }
        return try decoder.decode(Transcript.self, from: data)
    }

    public static func loadAlignment(forTranscriptAt url: URL) throws -> TranscriptAlignment? {
        let alignmentURL = url.deletingLastPathComponent().appendingPathComponent("alignment.json")
        guard FileManager.default.fileExists(atPath: alignmentURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: alignmentURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptAlignment.self, from: data)
    }

    public static func save(_ transcript: Transcript, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transcript)
        try data.write(to: url, options: .atomic)
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regularFormatter = ISO8601DateFormatter()
        regularFormatter.formatOptions = [.withInternetDateTime]

        if let date = fractionalFormatter.date(from: value)
            ?? regularFormatter.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected date string to be ISO8601-formatted."
        )
    }
}
