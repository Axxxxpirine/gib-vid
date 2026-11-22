import AVFoundation
import UIKit

/// Transforme ce que yt-dlp a téléchargé en un fichier que Photos accepte.
///
/// Sans ffmpeg, YouTube & co. fournissent souvent la vidéo et l'audio séparément :
/// AVFoundation les réunit dans un MP4, sans réencoder quand c'est possible.
enum VideoAssembler {
    enum Failure: LocalizedError {
        case noVideo, unsupported

        var errorDescription: String? {
            switch self {
            case .noVideo: "Le fichier téléchargé ne contient pas de vidéo."
            case .unsupported: "Ce format vidéo n’est pas compatible avec Photos."
            }
        }
    }

    static func photosReady(from files: [URL], output: URL) async throws -> URL {
        if files.count == 1, UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(files[0].path) {
            return files[0]
        }

        // Une AVAssetTrack ne retient pas son asset : on les garde en vie jusqu'à la fin.
        let assets = files.map { AVURLAsset(url: $0) }
        var video: (track: AVAssetTrack, range: CMTimeRange, transform: CGAffineTransform)?
        var audio: (track: AVAssetTrack, range: CMTimeRange)?
        for asset in assets {
            if video == nil, let track = try await asset.loadTracks(withMediaType: .video).first {
                let (range, transform) = try await track.load(.timeRange, .preferredTransform)
                video = (track, range, transform)
            }
            // La dernière piste audio l'emporte : c'est celle du fichier audio séparé.
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                audio = (track, try await track.load(.timeRange))
            }
        }
        guard let video else { throw Failure.noVideo }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.unsupported
        }
        try videoTrack.insertTimeRange(video.range, of: video.track, at: .zero)
        videoTrack.preferredTransform = video.transform

        if let audio, let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let duration = CMTimeMinimum(audio.range.duration, video.range.duration)
            try audioTrack.insertTimeRange(CMTimeRange(start: audio.range.start, duration: duration), of: audio.track, at: .zero)
        }

        // D'abord sans réencodage (instantané), sinon réencodage en H.264/HEVC.
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            try? FileManager.default.removeItem(at: output)
            guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            do {
                try await session.export(to: output, as: .mp4)
                if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(output.path) {
                    withExtendedLifetime(assets) {}
                    return output
                }
            } catch {
                continue
            }
        }
        withExtendedLifetime(assets) {}
        throw Failure.unsupported
    }
}
