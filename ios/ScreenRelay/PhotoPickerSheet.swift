import MobileCoreServices
import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct PhotoPickerSheet: View {
    let onPick: ([ImagePick]) -> Void

    var body: some View {
        if #available(iOS 14.0, *) {
            ModernPhotoPicker(onPick: onPick)
        } else {
            LegacyPhotoPicker(onPick: onPick)
        }
    }
}

@available(iOS 14.0, *)
private struct ModernPhotoPicker: UIViewControllerRepresentable {
    let onPick: ([ImagePick]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: ([ImagePick]) -> Void

        init(onPick: @escaping ([ImagePick]) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPick(results.map { .provider($0.itemProvider) })
        }
    }
}

private struct LegacyPhotoPicker: UIViewControllerRepresentable {
    let onPick: ([ImagePick]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
            DispatchQueue.main.async { onPick([.prepared(.failure(ImageUploadIssue.unavailable))]) }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.mediaTypes = [kUTTypeImage as String]
        picker.imageExportPreset = .current
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPick: ([ImagePick]) -> Void

        init(onPick: @escaping ([ImagePick]) -> Void) {
            self.onPick = onPick
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick([])
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let asset = info[.phAsset] as? PHAsset
            let resource = asset.flatMap {
                PHAssetResource.assetResources(for: $0).first { $0.type == .photo }
            }
            if let file = info[.imageURL] as? URL {
                let prepared = Result {
                    try ImageUploadStore.stage(file, suggestedName: resource?.originalFilename,
                                               typeHint: info[.mediaType] as? String)
                }
                onPick([.prepared(prepared)])
            } else if let resource {
                onPick([.asset(resource)])
            } else if let image = info[.originalImage] as? UIImage,
                      let jpeg = image.jpegData(compressionQuality: 1) {
                onPick([.prepared(Result { try ImageUploadStore.stageLegacyJPEG(jpeg, suggestedName: nil) })])
            } else {
                onPick([.prepared(.failure(ImageUploadIssue.unavailable))])
            }
        }
    }
}
