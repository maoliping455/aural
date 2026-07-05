import Foundation

public enum TranscriptExportFormat: String, CaseIterable, Equatable, Sendable {
    case srt
    case plainText
    case timestampedText

    public var displayName: String {
        switch self {
        case .srt:
            return "字幕 SRT"
        case .plainText:
            return "纯文字"
        case .timestampedText:
            return "带分段时间"
        }
    }

    public var fileExtension: String {
        switch self {
        case .srt:
            return "srt"
        case .plainText, .timestampedText:
            return "txt"
        }
    }

    public var filenameSuffix: String {
        switch self {
        case .srt:
            return "-字幕"
        case .plainText:
            return "-转写"
        case .timestampedText:
            return "-分段时间"
        }
    }
}

public enum TranscriptExportRenderer {
    public static func render(_ transcript: Transcript, format: TranscriptExportFormat) -> String {
        switch format {
        case .srt:
            return renderSRT(transcript)
        case .plainText:
            return renderPlainText(transcript)
        case .timestampedText:
            return renderTimestampedText(transcript)
        }
    }

    private static func renderPlainText(_ transcript: Transcript) -> String {
        let segments = normalizedSegments(in: transcript)
        if !segments.isEmpty {
            return segments.map(\.text).joined(separator: "\n") + "\n"
        }

        let fallbackText = cleanExportText(transcript.text)
        return fallbackText.isEmpty ? "" : fallbackText + "\n"
    }

    private static func renderTimestampedText(_ transcript: Transcript) -> String {
        let lines = normalizedSegments(in: transcript).map { segment in
            "[\(formatPlainTime(segment.startSec)) - \(formatPlainTime(segment.endSec))] \(segment.text)"
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func renderSRT(_ transcript: Transcript) -> String {
        let cues = normalizedSegments(in: transcript).enumerated().map { index, segment in
            """
            \(index + 1)
            \(formatSRTTime(segment.startSec)) --> \(formatSRTTime(segment.endSec))
            \(segment.text)
            """
        }
        return cues.isEmpty ? "" : cues.joined(separator: "\n\n") + "\n"
    }

    private struct ExportSegment {
        var startSec: Double
        var endSec: Double
        var text: String
    }

    private static func normalizedSegments(in transcript: Transcript) -> [ExportSegment] {
        let nonEmptySegments = transcript.segments.compactMap { segment -> (segment: TranscriptSegment, text: String)? in
            let text = cleanExportText(segment.text)
            guard !text.isEmpty else {
                return nil
            }
            return (segment, text)
        }

        return nonEmptySegments.enumerated().map { index, item in
            let startSec = normalizedSecond(item.segment.startSec)
            let nextStartSec = nonEmptySegments.dropFirst(index + 1).first.map { normalizedSecond($0.segment.startSec) }
            let endSec = normalizedEndSecond(
                segmentEndSec: item.segment.endSec,
                startSec: startSec,
                nextStartSec: nextStartSec,
                durationSec: transcript.audioDurationSec
            )
            return ExportSegment(startSec: startSec, endSec: endSec, text: item.text)
        }
    }

    private static func normalizedSecond(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else {
            return 0
        }
        return seconds
    }

    private static func normalizedEndSecond(
        segmentEndSec: Double,
        startSec: Double,
        nextStartSec: Double?,
        durationSec: Double
    ) -> Double {
        if segmentEndSec.isFinite, segmentEndSec > startSec {
            return segmentEndSec
        }
        if let nextStartSec, nextStartSec.isFinite, nextStartSec > startSec {
            return nextStartSec
        }
        if durationSec.isFinite, durationSec > startSec {
            return durationSec
        }
        return startSec + 2
    }

    private static func cleanExportText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func formatPlainTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let secs = value % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let totalMilliseconds = max(0, Int((seconds * 1000).rounded()))
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }
}
