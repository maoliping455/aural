import Foundation

public struct TranscriptTextSlice: Equatable, Sendable {
    public var startOffset: Int
    public var endOffset: Int
    public var text: String

    public init(startOffset: Int, endOffset: Int, text: String) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.text = text
    }
}

public struct TranscriptTextHighlight: Equatable, Sendable {
    public var sliceStartOffset: Int
    public var sliceEndOffset: Int
    public var highlightEndOffset: Int
    public var text: String

    public init(sliceStartOffset: Int, sliceEndOffset: Int, highlightEndOffset: Int, text: String) {
        self.sliceStartOffset = sliceStartOffset
        self.sliceEndOffset = sliceEndOffset
        self.highlightEndOffset = highlightEndOffset
        self.text = text
    }
}

public enum TranscriptPlaybackSlicer {
    public static func slices(in text: String) -> [TranscriptTextSlice] {
        let characters = Array(text)
        guard !characters.isEmpty else {
            return []
        }

        var slices: [TranscriptTextSlice] = []
        var startOffset = 0
        for index in characters.indices {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if isBoundary(characters[index], previous: previous, next: next) {
                appendSlice(
                    characters: characters,
                    startOffset: startOffset,
                    endOffset: index + 1,
                    to: &slices
                )
                startOffset = index + 1
            }
        }

        appendSlice(
            characters: characters,
            startOffset: startOffset,
            endOffset: characters.count,
            to: &slices
        )
        return slices
    }

    public static func activeSlice(in segment: TranscriptSegment, at time: TimeInterval) -> TranscriptTextSlice? {
        activeSliceProgress(in: segment, at: time)?.slice
    }

    public static func activeHighlight(in segment: TranscriptSegment, at time: TimeInterval) -> TranscriptTextHighlight? {
        guard let progress = activeSliceProgress(in: segment, at: time) else {
            return nil
        }

        let endOffset = progressEndOffset(in: progress.slice, ratio: progress.localRatio)
        return TranscriptTextHighlight(
            sliceStartOffset: progress.slice.startOffset,
            sliceEndOffset: progress.slice.endOffset,
            highlightEndOffset: endOffset,
            text: progress.slice.text
        )
    }

    public static func activeHighlight(
        in segment: TranscriptSegment,
        at time: TimeInterval,
        alignmentItems: [TranscriptAlignmentItem]
    ) -> TranscriptTextHighlight? {
        let items = itemsForSegment(segment, alignmentItems: alignmentItems)
        guard
            !items.isEmpty,
            let activeItem = activeItem(in: items, at: time),
            let spans = alignmentSpans(in: segment.text, items: items),
            let activeSpan = spans.first(where: { $0.itemIndex == activeItem.index }),
            let activeSlice = slices(in: segment.text).first(where: {
                activeSpan.startOffset >= $0.startOffset && activeSpan.startOffset < $0.endOffset
            })
        else {
            return nil
        }

        return TranscriptTextHighlight(
            sliceStartOffset: activeSlice.startOffset,
            sliceEndOffset: activeSlice.endOffset,
            highlightEndOffset: min(max(activeSpan.endOffset, activeSlice.startOffset), activeSlice.endOffset),
            text: activeSlice.text
        )
    }

    public static func activeText(in segment: TranscriptSegment, at time: TimeInterval) -> String? {
        activeSlice(in: segment, at: time)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func seekTime(
        in segment: TranscriptSegment,
        atTextOffset offset: Int?,
        alignmentItems: [TranscriptAlignmentItem]
    ) -> TimeInterval {
        guard let offset else {
            return segment.startSec
        }

        let characterCount = segment.text.count
        guard characterCount > 0 else {
            return segment.startSec
        }

        let clampedOffset = min(max(offset, 0), characterCount - 1)
        let items = itemsForSegment(segment, alignmentItems: alignmentItems)
        if
            !items.isEmpty,
            let spans = alignmentSpans(in: segment.text, items: items),
            let span = spans.first(where: { clampedOffset >= $0.startOffset && clampedOffset < $0.endOffset }),
            let item = items.first(where: { $0.index == span.itemIndex })
        {
            return max(segment.startSec, item.startSec)
        }

        let duration = max(segment.endSec - segment.startSec, 0)
        guard duration > 0 else {
            return segment.startSec
        }

        let ratio = min(max(Double(clampedOffset) / Double(characterCount), 0), 1)
        return segment.startSec + duration * ratio
    }

    private static func activeSliceProgress(
        in segment: TranscriptSegment,
        at time: TimeInterval
    ) -> (slice: TranscriptTextSlice, localRatio: Double)? {
        guard time >= segment.startSec else {
            return nil
        }

        let slices = slices(in: segment.text)
        guard !slices.isEmpty else {
            return nil
        }

        let duration = max(segment.endSec - segment.startSec, 0)
        guard duration > 0 else {
            return (slices[0], 0)
        }

        let elapsed = min(max(time - segment.startSec, 0), duration)
        let ratio = min(max(elapsed / duration, 0), 1)
        if ratio >= 0.999 {
            return (slices[slices.count - 1], 1)
        }

        let weights = slices.map { max(displayWeight($0.text), 1) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else {
            return (slices[0], 0)
        }

        let target = ratio * Double(totalWeight)
        var cumulative = 0
        for (index, weight) in weights.enumerated() {
            let previous = cumulative
            cumulative += weight
            if target <= Double(cumulative) {
                let localTarget = target - Double(previous)
                let localRatio = min(max(localTarget / Double(weight), 0), 1)
                return (slices[index], localRatio)
            }
        }
        return (slices[slices.count - 1], 1)
    }

    private struct AlignmentTextSpan {
        var itemIndex: Int
        var startOffset: Int
        var endOffset: Int
    }

    private static func itemsForSegment(
        _ segment: TranscriptSegment,
        alignmentItems: [TranscriptAlignmentItem]
    ) -> [TranscriptAlignmentItem] {
        if
            let start = segment.alignmentItemStart,
            let end = segment.alignmentItemEnd,
            start < end
        {
            return alignmentItems
                .filter { $0.index >= start && $0.index < end }
                .sorted { $0.index < $1.index }
        }

        let lower = segment.startSec - 0.05
        let upper = segment.endSec + 0.05
        return alignmentItems
            .filter { $0.endSec >= lower && $0.startSec <= upper }
            .sorted { $0.index < $1.index }
    }

    private static func activeItem(
        in items: [TranscriptAlignmentItem],
        at time: TimeInterval
    ) -> TranscriptAlignmentItem? {
        guard
            let first = items.first,
            time >= first.startSec
        else {
            return nil
        }

        if let exact = items.first(where: { time >= $0.startSec && time <= max($0.endSec, $0.startSec) }) {
            return exact
        }
        if let previous = items.last(where: { $0.startSec <= time }) {
            return previous
        }
        return items.first
    }

    private static func alignmentSpans(
        in text: String,
        items: [TranscriptAlignmentItem]
    ) -> [AlignmentTextSpan]? {
        let normalizedText = normalizedCharactersWithOffsets(text)
        guard !normalizedText.characters.isEmpty else {
            return nil
        }

        var cursor = 0
        var spans: [AlignmentTextSpan] = []
        for item in items {
            let token = normalizedCharacters(item.text)
            guard !token.isEmpty else {
                continue
            }
            guard let range = findSubsequence(token, in: normalizedText.characters, from: cursor) else {
                continue
            }

            let startOffset = normalizedText.offsets[range.lowerBound]
            let endOffset = normalizedText.offsets[range.upperBound - 1] + 1
            spans.append(
                AlignmentTextSpan(
                    itemIndex: item.index,
                    startOffset: startOffset,
                    endOffset: endOffset
                )
            )
            cursor = range.upperBound
        }

        return spans.isEmpty ? nil : spans
    }

    private static func normalizedCharactersWithOffsets(_ text: String) -> (characters: [Character], offsets: [Int]) {
        var characters: [Character] = []
        var offsets: [Int] = []
        for (offset, character) in Array(text).enumerated() {
            let normalized = normalizedCharacters(String(character))
            for normalizedCharacter in normalized {
                characters.append(normalizedCharacter)
                offsets.append(offset)
            }
        }
        return (characters, offsets)
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        var result: [Character] = []
        for character in text {
            guard isAlignmentMatchCharacter(character) else {
                continue
            }
            result.append(contentsOf: Array(String(character).lowercased()))
        }
        return result
    }

    private static func findSubsequence(
        _ needle: [Character],
        in haystack: [Character],
        from start: Int
    ) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return nil
        }
        let startIndex = min(max(start, 0), haystack.count)
        guard startIndex <= haystack.count - needle.count else {
            return nil
        }

        for index in startIndex...(haystack.count - needle.count) {
            var matched = true
            for offset in needle.indices where haystack[index + offset] != needle[offset] {
                matched = false
                break
            }
            if matched {
                return index..<(index + needle.count)
            }
        }
        return nil
    }

    private static func appendSlice(
        characters: [Character],
        startOffset: Int,
        endOffset: Int,
        to slices: inout [TranscriptTextSlice]
    ) {
        guard startOffset < endOffset else {
            return
        }
        let text = String(characters[startOffset..<endOffset])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        slices.append(
            TranscriptTextSlice(
                startOffset: startOffset,
                endOffset: endOffset,
                text: text
            )
        )
    }

    private static func displayWeight(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || isPunctuation(scalar) {
                return total
            }
            return total + 1
        }
    }

    private static func progressEndOffset(in slice: TranscriptTextSlice, ratio: Double) -> Int {
        let clampedRatio = min(max(ratio, 0), 1)
        if clampedRatio <= 0 {
            return slice.startOffset
        }
        if clampedRatio >= 0.995 {
            return slice.endOffset
        }

        let units = playbackUnits(in: slice.text)
        guard !units.isEmpty else {
            return slice.startOffset
        }

        let totalWeight = units.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return slice.startOffset
        }

        let target = clampedRatio * Double(totalWeight)
        var cumulative = 0
        for unit in units {
            cumulative += unit.weight
            if target <= Double(cumulative) {
                return min(slice.startOffset + unit.endOffset, slice.endOffset)
            }
        }
        return slice.endOffset
    }

    private struct PlaybackUnit {
        var endOffset: Int
        var weight: Int
    }

    private static func playbackUnits(in text: String) -> [PlaybackUnit] {
        let characters = Array(text)
        var units: [PlaybackUnit] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if isWhitespaceOrPunctuation(character) {
                index += 1
                continue
            }

            if isASCIIWordCharacter(character) {
                var end = index + 1
                while end < characters.count, isASCIIWordCharacter(characters[end]) {
                    end += 1
                }
                units.append(PlaybackUnit(endOffset: end, weight: max(end - index, 1)))
                index = end
            } else {
                units.append(PlaybackUnit(endOffset: index + 1, weight: 1))
                index += 1
            }
        }
        return units
    }

    private static func isBoundary(_ character: Character, previous: Character?, next: Character?) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }

        switch scalar.value {
        case 0x3001, 0x3002, 0xFF0C, 0xFF1A, 0xFF1B, 0xFF01, 0xFF1F:
            return true
        case 44, 46, 58, 59, 33, 63:
            if character == ".", isLikelyAbbreviationBoundary(previous: previous, next: next) {
                return false
            }
            if character == "." || character == "," || character == ":" {
                if let previous, let next, isASCIIDigit(previous), isASCIIDigit(next) {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    private static func isWhitespaceOrPunctuation(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar) || isPunctuation(scalar)
    }

    private static func isAlignmentMatchCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
        }
    }

    private static func isPunctuation(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 33, 44, 46, 58, 59, 63,
             0x3001, 0x3002, 0xFF0C, 0xFF1A, 0xFF1B, 0xFF01, 0xFF1F:
            return true
        default:
            return false
        }
    }

    private static func isLikelyAbbreviationBoundary(previous: Character?, next: Character?) -> Bool {
        guard let previous, let next else {
            return false
        }
        return isASCIIUppercase(previous) && (isASCIIUppercase(next) || next.isWhitespace)
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return isASCIIWordCharacter(scalar)
    }

    private static func isASCIIWordCharacter(_ scalar: UnicodeScalar) -> Bool {
        isASCIILetter(scalar) || (48...57).contains(Int(scalar.value)) || scalar.value == 39 || scalar.value == 45
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (48...57).contains(Int(scalar.value))
    }

    private static func isASCIIUppercase(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (65...90).contains(Int(scalar.value))
    }
}
