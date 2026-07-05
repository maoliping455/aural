import Foundation

public enum TranscriptCleanup {
    public static func removingExcessiveRepetition(from transcript: Transcript) -> Transcript {
        var next = transcript
        let cleanedSegments = transcript.segments.map { segment in
            var nextSegment = segment
            nextSegment.text = normalizeReadableText(segment.text)
            if let rawText = segment.rawText {
                nextSegment.rawText = collapseRepeatedSentences(rawText)
            }
            return nextSegment
        }
        next.segments = mergeBriefLatinConnectorSegments(mergeOrphanLatinSegments(collapseRepeatedSegments(cleanedSegments)))

        let segmentText = next.segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        next.text = segmentText.isEmpty ? normalizeReadableText(transcript.text) : segmentText
        if let rawText = transcript.rawText {
            next.rawText = collapseRepeatedSentences(rawText)
        }
        if let normalizedText = transcript.normalizedText {
            next.normalizedText = normalizeReadableText(normalizedText)
        }
        return next
    }

    public static func collapseRepeatedSentences(
        _ text: String,
        minRunLength: Int = 4,
        keepCount: Int = 1
    ) -> String {
        let units = sentenceUnits(from: text)
        guard units.count >= minRunLength else {
            return text
        }

        var result: [String] = []
        var index = 0
        while index < units.count {
            let normalized = normalizedRepeatKey(units[index])
            var end = index + 1
            while end < units.count, !normalized.isEmpty, normalizedRepeatKey(units[end]) == normalized {
                end += 1
            }

            let count = end - index
            if !normalized.isEmpty, count >= minRunLength {
                result.append(contentsOf: units[index..<min(index + keepCount, end)])
            } else {
                result.append(contentsOf: units[index..<end])
            }
            index = end
        }

        return result.joined()
    }

    private static func collapseRepeatedSegments(
        _ segments: [TranscriptSegment],
        minRunLength: Int = 3,
        keepCount: Int = 1
    ) -> [TranscriptSegment] {
        guard segments.count >= minRunLength else {
            return segments
        }

        var result: [TranscriptSegment] = []
        var index = 0
        while index < segments.count {
            let normalized = normalizedRepeatKey(segments[index].text)
            var end = index + 1
            while end < segments.count, !normalized.isEmpty, normalizedRepeatKey(segments[end].text) == normalized {
                end += 1
            }

            let count = end - index
            if !normalized.isEmpty, count >= minRunLength {
                result.append(contentsOf: segments[index..<min(index + keepCount, end)])
            } else {
                result.append(contentsOf: segments[index..<end])
            }
            index = end
        }

        return result
    }

    private static func normalizeReadableText(_ text: String) -> String {
        normalizeEnglishSpacing(normalizeSpacedAcronyms(collapseRepeatedSentences(stripASRTemplateArtifacts(text))))
    }

    private static func stripASRTemplateArtifacts(_ text: String) -> String {
        var next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        next = next.replacingOccurrences(
            of: #"(?i)^\s*(?:language\s*)?(?:Chinese|English|Japanese|Cantonese|Mandarin|zh|en|ja|yue)?\s*<asr_text>\s*"#,
            with: "",
            options: .regularExpression
        )
        next = next.replacingOccurrences(
            of: #"(?i)</asr_text>\s*"#,
            with: "",
            options: .regularExpression
        )
        next = next.replacingOccurrences(
            of: #"<\|[^|>]+?\|>\s*"#,
            with: "",
            options: .regularExpression
        )
        return next.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeEnglishSpacing(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count >= 3 else {
            return text
        }

        var result = ""
        for index in characters.indices {
            let character = characters[index]
            result.append(character)

            let nextIndex = index + 1
            guard nextIndex < characters.count else {
                continue
            }
            guard isASCIISeparatorPunctuation(character), !characters[nextIndex].isWhitespace else {
                continue
            }
            guard index > 0, isASCIILetterOrDigit(characters[index - 1]), isASCIILetter(characters[nextIndex]) else {
                continue
            }
            if character == ".", isLikelySingleLetterAbbreviation(characters, before: index, after: nextIndex) {
                continue
            }
            result.append(" ")
        }
        return result
    }

    private static func normalizeSpacedAcronyms(_ text: String) -> String {
        guard text.contains(" ") else {
            return text
        }

        let pattern = #"(?<![A-Za-z])(?:[A-Z]\s+){1,7}[A-Z](?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else {
            return text
        }

        var result = text
        for match in matches.reversed() {
            let matchedText = nsText.substring(with: match.range)
            let compact = matchedText.filter { !$0.isWhitespace }
            guard shouldMergeSpacedAcronym(match.range, compact: compact, in: text) else {
                continue
            }
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: compact)
            }
        }
        return result
    }

    private static func shouldMergeSpacedAcronym(_ range: NSRange, compact: String, in text: String) -> Bool {
        guard (2...8).contains(compact.count), compact.allSatisfy({ $0.isUppercase }) else {
            return false
        }

        let characters = Array(text)
        guard let characterRange = Range(range, in: text) else {
            return false
        }
        let startOffset = text.distance(from: text.startIndex, to: characterRange.lowerBound)
        let endOffset = text.distance(from: text.startIndex, to: characterRange.upperBound)
        let before = startOffset > 0 ? characters[startOffset - 1] : nil
        let after = endOffset < characters.count ? characters[endOffset] : nil

        if let before, isASCIILetter(before) {
            return false
        }
        if let after, isASCIILetter(after), !after.isUppercase {
            return false
        }

        let touchesCJK = [before, after].contains { character in
            guard let character else { return false }
            return character.unicodeScalars.contains { isCJK($0) }
        }
        let boundedByPunctuationOrSpace = [before, after].contains { character in
            guard let character else { return true }
            return character.isWhitespace || isASCIILeadingPunctuation(character) || isChinesePunctuation(character)
        }

        return touchesCJK || boundedByPunctuationOrSpace
    }

    private static func mergeBriefLatinConnectorSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if
                var previous = result.last,
                shouldMergeBriefLatinConnector(segment, after: previous)
            {
                let previousText = previous.text
                let previousRawText = previous.rawText ?? previous.text
                previous.text = joinReadableFragments(previousText, text)
                if let rawText = segment.rawText {
                    previous.rawText = joinReadableFragments(previousRawText, rawText)
                }
                previous.endSec = max(previous.endSec, segment.endSec)
                previous.alignmentItemEnd = segment.alignmentItemEnd ?? previous.alignmentItemEnd
                result[result.count - 1] = previous
                continue
            }
            result.append(segment)
        }
        return result
    }

    private static func shouldMergeBriefLatinConnector(_ segment: TranscriptSegment, after previous: TranscriptSegment) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 28 else {
            return false
        }
        guard segment.endSec - segment.startSec <= 3.5, segmentGap(from: previous, toStart: segment.startSec) <= 1.5 else {
            return false
        }
        guard latinWordCount(text) <= 4, text.unicodeScalars.contains(where: isASCIILetter) else {
            return false
        }
        guard text.unicodeScalars.allSatisfy({ scalar in
            isASCIILetter(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) || isASCIIJoinPunctuation(scalar)
        }) else {
            return false
        }

        let normalized = normalizedBriefLatinPhrase(text)
        let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuationCue = text.last == ","
            || previousText.last == ","
            || (text.first?.isLowercase == true)
            || briefLatinConnectors.contains(normalized)
        return continuationCue && !standaloneBriefLatinPhrases.contains(normalized)
    }

    private static let briefLatinConnectors: Set<String> = [
        "and",
        "but",
        "because",
        "for example",
        "i mean",
        "in fact",
        "of course",
        "or",
        "so",
        "then",
        "you know"
    ]

    private static let standaloneBriefLatinPhrases: Set<String> = [
        "no",
        "nope",
        "ok",
        "okay",
        "right",
        "sure",
        "thanks",
        "yes",
        "yep"
    ]

    private static func normalizedBriefLatinPhrase(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if isASCIILetter(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let phrase = String(scalars)
        return phrase
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func latinWordCount(_ text: String) -> Int {
        normalizedBriefLatinPhrase(text).split(separator: " ").count
    }

    private static func mergeOrphanLatinSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if
                var previous = result.last,
                shouldMergeLatinOrphan(segment, after: previous)
            {
                let previousText = previous.text
                let previousRawText = previous.rawText ?? previous.text
                previous.text = joinLatinFragments(previousText, text)
                if let rawText = segment.rawText {
                    previous.rawText = joinLatinFragments(previousRawText, rawText)
                }
                previous.endSec = max(previous.endSec, segment.endSec)
                previous.alignmentItemEnd = segment.alignmentItemEnd ?? previous.alignmentItemEnd
                result[result.count - 1] = previous
                continue
            }
            result.append(segment)
        }
        return result
    }

    private static func shouldMergeLatinOrphan(_ segment: TranscriptSegment, after previous: TranscriptSegment) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let orphanLetters = text.unicodeScalars.filter { isASCIILetter($0) }
        guard !orphanLetters.isEmpty, orphanLetters.count <= 2 else {
            return false
        }
        guard text.unicodeScalars.allSatisfy({ scalar in
            isASCIILetter(scalar) || isASCIIJoinPunctuation(scalar)
        }) else {
            return false
        }
        guard let previousLastScalar = previous.text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last,
              isASCIILetterOrDigit(previousLastScalar)
        else {
            return false
        }
        let gap = segmentGap(from: previous, toStart: segment.startSec)
        return gap <= 1.5
    }

    private static func segmentGap(from previous: TranscriptSegment, toStart startSec: Double) -> Double {
        max(0, startSec - previous.endSec)
    }

    private static func joinLatinFragments(_ left: String, _ right: String) -> String {
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let leftLast = left.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last,
            let rightFirst = trimmedRight.unicodeScalars.first,
            isASCIILetterOrDigit(leftLast),
            isASCIILetter(rightFirst)
        else {
            return left + trimmedRight
        }
        return left + trimmedRight
    }

    private static func joinReadableFragments(_ left: String, _ right: String) -> String {
        let trimmedLeft = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeft.isEmpty else {
            return trimmedRight
        }
        guard !trimmedRight.isEmpty else {
            return trimmedLeft
        }
        guard let rightFirst = trimmedRight.first, !isASCIILeadingPunctuation(rightFirst) else {
            return trimmedLeft + trimmedRight
        }
        return trimmedLeft + " " + trimmedRight
    }

    private static func sentenceUnits(from text: String) -> [String] {
        var units: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if isSentenceTerminator(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    units.append(trimmed)
                }
                current = ""
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            units.append(trimmed)
        }
        return units
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 33, 46, 59, 63, 0x3002, 0xFF01, 0xFF1B, 0xFF1F:
            return true
        default:
            return false
        }
    }

    private static func normalizedRepeatKey(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            switch scalar.value {
            case 33, 34, 37, 39, 40, 41, 44, 46, 58, 59, 63,
                 0x3001, 0x3002, 0xFF01, 0xFF08, 0xFF09, 0xFF0C, 0xFF1A, 0xFF1B, 0xFF1F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).lowercased()
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return isASCIILetter(scalar)
    }

    private static func isASCIILetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        isASCIILetter(scalar) || (48...57).contains(Int(scalar.value))
    }

    private static func isASCIILetterOrDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return isASCIILetterOrDigit(scalar)
    }

    private static func isASCIIJoinPunctuation(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 33, 39, 44, 46, 58, 59, 63:
            return true
        default:
            return false
        }
    }

    private static func isASCIISeparatorPunctuation(_ character: Character) -> Bool {
        switch character {
        case ".", ",", ";", ":", "!", "?":
            return true
        default:
            return false
        }
    }

    private static func isASCIILeadingPunctuation(_ character: Character) -> Bool {
        switch character {
        case ",", ".", ";", ":", "!", "?":
            return true
        default:
            return false
        }
    }

    private static func isChinesePunctuation(_ character: Character) -> Bool {
        switch character {
        case "，", "。", "、", "；", "：", "！", "？", "（", "）", "《", "》", "“", "”", "‘", "’":
            return true
        default:
            return false
        }
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func isLikelySingleLetterAbbreviation(_ characters: [Character], before punctuationIndex: Int, after: Int) -> Bool {
        guard punctuationIndex > 0, after < characters.count else {
            return false
        }
        let previousTokenLength = asciiTokenLengthEnding(at: punctuationIndex - 1, in: characters)
        return previousTokenLength == 1
            && isASCIIUppercaseLetter(characters[punctuationIndex - 1])
            && isASCIIUppercaseLetter(characters[after])
    }

    private static func asciiTokenLengthEnding(at index: Int, in characters: [Character]) -> Int {
        guard characters.indices.contains(index) else {
            return 0
        }
        var length = 0
        var cursor = index
        while cursor >= 0, isASCIILetterOrDigit(characters[cursor]) {
            length += 1
            if cursor == 0 {
                break
            }
            cursor -= 1
        }
        return length
    }

    private static func isASCIIUppercaseLetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (65...90).contains(Int(scalar.value))
    }
}
