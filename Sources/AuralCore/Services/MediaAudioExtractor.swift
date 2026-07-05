import Foundation
@preconcurrency import AVFoundation

public enum MediaAudioExtractor {
    public static func extractAudio(from videoURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TaskStore.StoreError.mediaHasNoAudioTrack(videoURL.lastPathComponent)
        }
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TaskStore.StoreError.audioExtractionFailed("export session unavailable")
        }
        let exportSessionBox = ExportSessionBox(exportSession)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                switch exportSessionBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(
                        throwing: TaskStore.StoreError.audioExtractionFailed(
                            exportSessionBox.session.error?.localizedDescription ?? "export failed"
                        )
                    )
                case .cancelled:
                    continuation.resume(throwing: TaskStore.StoreError.audioExtractionFailed("export cancelled"))
                default:
                    continuation.resume(throwing: TaskStore.StoreError.audioExtractionFailed("unexpected export status"))
                }
            }
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
