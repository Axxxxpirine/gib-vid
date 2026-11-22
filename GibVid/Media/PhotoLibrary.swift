import Photos

enum PhotoLibrary {
    static func requestAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    static func saveVideo(at url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }
}
