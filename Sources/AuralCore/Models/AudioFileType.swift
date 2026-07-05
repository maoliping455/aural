import Foundation
import UniformTypeIdentifiers

public enum AudioFileType {
    public static let supportedExtensions: [String] = ["mp3", "m4a", "wav", "aac", "flac"]
    public static let supportedExtensionSet = Set(supportedExtensions)

    public static var supportedContentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensionSet.contains(url.pathExtension.lowercased())
    }
}

public enum VideoFileType {
    public static let supportedExtensions: [String] = ["mp4", "mov", "m4v"]
    public static let supportedExtensionSet = Set(supportedExtensions)

    public static var supportedContentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensionSet.contains(url.pathExtension.lowercased())
    }
}

public enum MediaFileType {
    public static let supportedExtensions = AudioFileType.supportedExtensions + VideoFileType.supportedExtensions
    public static let supportedExtensionSet = Set(supportedExtensions)

    public static var supportedContentTypes: [UTType] {
        AudioFileType.supportedContentTypes + VideoFileType.supportedContentTypes
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensionSet.contains(url.pathExtension.lowercased())
    }

    public static func isAudio(_ url: URL) -> Bool {
        AudioFileType.isSupported(url)
    }

    public static func isVideo(_ url: URL) -> Bool {
        VideoFileType.isSupported(url)
    }
}
