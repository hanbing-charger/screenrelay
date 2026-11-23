import AVFoundation
import MobileCoreServices
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct MediaPickerSheet: View {
    let kind: UploadKind
    let onPick: ([UploadSelection]) -> Void

    var body: some View {
        if #available(iOS 14.0, *) {
            ModernMediaPicker(kind: kind, onPick: onPick)
        } else {
            LegacyMediaPicker(kind: kind, onPick: onPick)
        }
    }
}

@available(iOS 14.0, *)
private struct ModernMediaPicker: UIViewControllerRepresentable {
    let kind: UploadKind
    let onPick: ([UploadSelection]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = kind == .photo ? .images : .videos
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(kind: kind, onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let kind: UploadKind
        private let onPick: ([UploadSelection]) -> Void

        init(kind: UploadKind, onPick: @escaping ([UploadSelection]) -> Void) {
            self.kind = kind
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPick(results.map { .provider($0.itemProvider, kind) })
        }
    }
}

private struct LegacyMediaPicker: UIViewControllerRepresentable {
    let kind: UploadKind
    let onPick: ([UploadSelection]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
            DispatchQueue.main.async { onPick([.prepared(.failure(UploadIssue.unavailable))]) }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        if kind == .photo {
            picker.mediaTypes = [kUTTypeImage as String]
            picker.imageExportPreset = .current
        } else {
            picker.mediaTypes = [kUTTypeMovie as String]
            picker.videoExportPreset = AVAssetExportPresetPassthrough
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(kind: kind, onPick: onPick) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let kind: UploadKind
        private let onPick: ([UploadSelection]) -> Void
        private var copyingMovie = false

        init(kind: UploadKind, onPick: @escaping ([UploadSelection]) -> Void) {
            self.kind = kind
            self.onPick = onPick
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            if !copyingMovie { onPick([]) }
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let asset = info[.phAsset] as? PHAsset
            if kind == .video {
                guard !copyingMovie else { return }
                guard let file = info[.mediaURL] as? URL else {
                    onPick([.prepared(.failure(UploadIssue.unavailable))])
                    return
                }
                let name = asset.flatMap {
                    PHAssetResource.assetResources(for: $0).first { $0.type == .video }?.originalFilename
                }
                copyMovie(file, suggestedName: name, picker: picker)
                return
            }

            let resource = asset.flatMap {
                PHAssetResource.assetResources(for: $0).first { $0.type == .photo }
            }
            if let file = info[.imageURL] as? URL {
                let prepared = Result {
                    try UploadStore.stageMedia(file, suggestedName: resource?.originalFilename,
                                               typeHint: info[.mediaType] as? String, kind: .photo)
                }
                onPick([.prepared(prepared)])
            } else if let resource {
                onPick([.asset(resource)])
            } else if let image = info[.originalImage] as? UIImage,
                      let jpeg = image.jpegData(compressionQuality: 1) {
                onPick([.prepared(Result { try UploadStore.stageLegacyJPEG(jpeg) })])
            } else {
                onPick([.prepared(.failure(UploadIssue.unavailable))])
            }
        }

        private func copyMovie(_ file: URL, suggestedName: String?, picker: UIImagePickerController) {
            copyingMovie = true
            // Keep the picker and its exported movie alive until the private copy finishes.
            picker.isModalInPresentation = true
            picker.view.isUserInteractionEnabled = false
            let indicator = UIActivityIndicatorView(style: .large)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            picker.view.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: picker.view.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: picker.view.centerYAnchor),
            ])
            indicator.startAnimating()

            Task {
                let result: Result<PendingUpload, Error>
                do {
                    result = .success(try await UploadStore.stageLegacyVideo(file, suggestedName: suggestedName))
                } catch {
                    result = .failure(error)
                }
                indicator.removeFromSuperview()
                picker.view.isUserInteractionEnabled = true
                picker.isModalInPresentation = false
                copyingMovie = false
                onPick([.prepared(result)])
            }
        }
    }
}

struct DocumentPickerSheet: UIViewControllerRepresentable {
    let onPick: ([UploadSelection]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: [kUTTypeItem as String], in: .open)
        }
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([UploadSelection]) -> Void

        init(onPick: @escaping ([UploadSelection]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ picker: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.map { .document($0) })
        }

        func documentPickerWasCancelled(_ picker: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
