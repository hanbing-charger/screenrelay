import Foundation
import Photos
import UniformTypeIdentifiers

enum CaptureKind: String {
    case screenshot
    case screenRecording = "screen-recording"
}

struct Capture {
    let localIdentifier: String
    let kind: CaptureKind
    let resource: PHAssetResource

    var filename: String { resource.originalFilename }
    var mimeType: String {
        UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
    }

    func export(to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            SyncModel.shared.libraryChanged()
        }
    }
}

enum CaptureLibrary {
    static func find(since start: Date, excluding processed: Set<String>) -> [Capture] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumScreenRecordings,
            options: nil
        )
        var recordings = Set<String>()
        albums.enumerateObjects { album, _, _ in
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                recordings.insert(asset.localIdentifier)
            }
        }

        var captures: [Capture] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            guard !processed.contains(asset.localIdentifier) else { return }

            let kind: CaptureKind
            let resourceType: PHAssetResourceType
            switch asset.mediaType {
            case .image where asset.mediaSubtypes.contains(.photoScreenshot):
                kind = .screenshot
                resourceType = .photo
            case .video where asset.mediaSubtypes.contains(.videoScreenRecording)
                || recordings.contains(asset.localIdentifier):
                kind = .screenRecording
                resourceType = .video
            default:
                return
            }

            if let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == resourceType }) {
                captures.append(Capture(localIdentifier: asset.localIdentifier, kind: kind, resource: resource))
            }
        }
        return captures
    }
}
