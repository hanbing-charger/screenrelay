import Combine
import Foundation
import ImageIO
import MobileCoreServices
import Photos
import UniformTypeIdentifiers

struct PendingImage: Codable, Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let addedAt: Date
}

enum ImageUploadIssue: LocalizedError {
    case unavailable
    case unsupported
    case pairingChanged
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "无法从相册读取这张图片。若保存在 iCloud，请确认原图已可用后重新选择。"
        case .unsupported:
            return "这张图片的格式暂不支持，未转换或上传。"
        case .pairingChanged:
            return "电脑配置已更改。请确认接收电脑后重试待传图片。"
        case .rejected(let code):
            switch code {
            case 400:
                return "电脑端拒绝图片上传。请确认电脑和手机两端均已更新至 0.7.0 或以上。"
            case 401, 403:
                return "电脑拒绝了配对凭据，请重新配对后重试。"
            case 413:
                return "图片超过电脑端的文件大小上限。"
            case 415:
                return "电脑端不支持此图片格式，请确认两端均已更新。"
            default:
                return "电脑端返回 HTTP \(code)。"
            }
        }
    }
}

enum ImagePick {
    case provider(NSItemProvider)
    case asset(PHAssetResource)
    case prepared(Result<PendingImage, Error>)
}

enum ImageUploadStore {
    private static let files = FileManager.default
    private static let formats: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "jpe": "image/jpeg", "jfif": "image/jpeg", "heic": "image/heic",
        "heif": "image/heif", "hif": "image/heif", "bmp": "image/bmp",
        "webp": "image/webp", "avif": "image/avif", "gif": "image/gif",
        "jxl": "image/jxl", "tif": "image/tiff", "tiff": "image/tiff",
        "dng": "image/x-adobe-dng",
    ]

    private static func directory() throws -> URL {
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        var directory = support.appendingPathComponent("ScreenRelayPickedImages", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        return directory
    }

    static func restore() throws -> [PendingImage] {
        let directory = try directory()
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries.compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent) else { return nil }
            let meta = entry.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: meta),
               let image = try? JSONDecoder().decode(PendingImage.self, from: data),
               image.id == id,
               files.fileExists(atPath: entry.appendingPathComponent("image").path) {
                return image
            }
            return nil
        }.sorted { $0.addedAt < $1.addedAt }
    }

    static func file(for image: PendingImage) throws -> URL {
        try directory().appendingPathComponent(image.id.uuidString, isDirectory: true)
            .appendingPathComponent("image")
    }

    static func remove(_ image: PendingImage) throws {
        try files.removeItem(at: file(for: image).deletingLastPathComponent())
    }

    static func stage(_ source: URL, suggestedName: String?, typeHint: String?) throws -> PendingImage {
        let detectedType = CGImageSourceCreateWithURL(source as CFURL, nil)
            .flatMap { CGImageSourceGetType($0) }.map { $0 as String }
        let sourceExtension = source.pathExtension.lowercased()
        let name = suggestedName ?? source.lastPathComponent
        let suggestedExtension = (name as NSString).pathExtension.lowercased()

        let typedExtension = preferredExtension(detectedType) ?? preferredExtension(typeHint)
        let extensionGuess = [sourceExtension, suggestedExtension].first { formats[$0] != nil }
        let chosenExtension: String
        if extensionGuess == "dng" && (typedExtension == "tiff" || typedExtension == "tif") {
            // DNG is a TIFF-based raw format.
            chosenExtension = "dng"
        } else if let typedExtension {
            guard let mime = formats[typedExtension] else { throw ImageUploadIssue.unsupported }
            chosenExtension = extensionGuess.flatMap { formats[$0] == mime ? $0 : nil } ?? typedExtension
        } else if let extensionGuess {
            chosenExtension = extensionGuess
        } else {
            throw ImageUploadIssue.unsupported
        }
        guard let mime = formats[chosenExtension] else { throw ImageUploadIssue.unsupported }
        return try stage(name: normalizedName(name, suffix: chosenExtension), mimeType: mime) { destination in
            try files.copyItem(at: source, to: destination)
        }
    }

    static func stageLegacyJPEG(_ bytes: Data, suggestedName: String?) throws -> PendingImage {
        try stage(name: normalizedName(suggestedName ?? "图片", suffix: "jpg"), mimeType: "image/jpeg") { destination in
            try bytes.write(to: destination, options: [.completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func stage(_ resource: PHAssetResource) async throws -> PendingImage {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: file) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                ofItemAtPath: file.path)
        return try stage(file, suggestedName: resource.originalFilename, typeHint: resource.uniformTypeIdentifier)
    }

    private static func stage(
        name: String, mimeType: String, write: (URL) throws -> Void
    ) throws -> PendingImage {
        let image = PendingImage(id: UUID(), filename: name, mimeType: mimeType, addedAt: Date())
        let destination = try file(for: image)
        let folder = destination.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        do {
            try write(destination)
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw ImageUploadIssue.unavailable }
            try files.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            try JSONEncoder().encode(image).write(to: folder.appendingPathComponent("metadata.json"),
                                                 options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return image
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    @available(iOS 14.0, *)
    static func stage(_ provider: NSItemProvider) async throws -> PendingImage {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
        let type = types.first { item in
            preferredExtension(item.identifier).map { formats[$0] != nil } ?? false
        } ?? types.first
        guard let type else { throw ImageUploadIssue.unsupported }
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                guard let source else {
                    continuation.resume(throwing: error ?? ImageUploadIssue.unavailable)
                    return
                }
                continuation.resume(with: Result {
                    // The picker-owned file is valid only until this callback returns.
                    try Self.stage(source, suggestedName: name, typeHint: type.identifier)
                })
            }
        }
    }

    private static func preferredExtension(_ type: String?) -> String? {
        guard let type else { return nil }
        if type == "com.adobe.raw-image" { return "dng" }
        if #available(iOS 14.0, *), let ext = UTType(type)?.preferredFilenameExtension {
            return ext.lowercased()
        }
        guard let ext = UTTypeCopyPreferredTagWithClass(type as CFString, kUTTagClassFilenameExtension) else {
            return nil
        }
        return (ext.takeRetainedValue() as String).lowercased()
    }

    private static func normalizedName(_ name: String, suffix ext: String) -> String {
        let separators = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let clean = name.components(separatedBy: separators).joined(separator: "_")
        let sourceExt = (clean as NSString).pathExtension.lowercased()
        var stem = formats[sourceExt] == nil ? clean : (clean as NSString).deletingPathExtension
        stem = stem.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while stem.utf8.count > 180 { stem.removeLast() }
        return (stem.isEmpty ? "图片" : stem) + "." + ext
    }
}

@MainActor
final class ImageUploadModel: ObservableObject {
    @Published private(set) var pending: [PendingImage] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    init() {
        do {
            pending = try ImageUploadStore.restore()
        } catch {
            message = "无法读取待传图片。"
        }
    }

    func accept(_ selection: [ImagePick], sync: SyncModel) {
        guard !busy, !selection.isEmpty else { return }
        busy = true
        message = "正在读取所选图片…"
        let settings = sync.settings
        Task {
            var prepared: [PendingImage] = []
            var importFailures = 0
            var firstError: String?
            for source in selection {
                do {
                    let image: PendingImage
                    switch source {
                    case .provider(let provider):
                        if #available(iOS 14, *) {
                            image = try await ImageUploadStore.stage(provider)
                        } else {
                            throw ImageUploadIssue.unavailable
                        }
                    case .prepared(let result):
                        image = try result.get()
                    case .asset(let resource):
                        image = try await ImageUploadStore.stage(resource)
                    }
                    pending.append(image)
                    prepared.append(image)
                } catch {
                    importFailures += 1
                    firstError = firstError ?? error.localizedDescription
                }
            }
            if let settings {
                await upload(prepared, to: settings, sync: sync, importFailures: importFailures, importError: firstError)
            } else if prepared.isEmpty {
                message = firstError ?? ImageUploadIssue.unavailable.localizedDescription
            } else {
                message = "\(prepared.count) 张图片已加入待传。请先配对电脑再重试。"
                if importFailures > 0 {
                    message = (message ?? "") + "\(importFailures) 张未能读取。\(firstError ?? "")"
                }
            }
            busy = false
        }
    }

    func retry(sync: SyncModel) {
        guard !busy, !pending.isEmpty, let settings = sync.settings else { return }
        let images = pending
        busy = true
        Task {
            await upload(images, to: settings, sync: sync, importFailures: 0, importError: nil)
            busy = false
        }
    }

    func discardPending() {
        guard !busy else { return }
        var remaining: [PendingImage] = []
        for image in pending {
            do {
                try ImageUploadStore.remove(image)
            } catch {
                remaining.append(image)
            }
        }
        pending = remaining
        message = pending.isEmpty ? "已清除待传副本。" : "有待传副本未能清除。"
    }

    private func upload(
        _ images: [PendingImage], to settings: ReceiverSettings, sync: SyncModel,
        importFailures: Int, importError: String?
    ) async {
        var sent = 0
        var firstError: String?
        for image in images {
            message = "正在上传 \(image.filename)"
            do {
                let file = try ImageUploadStore.file(for: image)
                let status = try await sync.sendPickedImage(image, file: file, to: settings)
                if status == 200 || status == 201 {
                    try ImageUploadStore.remove(image)
                    pending.removeAll { $0.id == image.id }
                    sent += 1
                } else {
                    firstError = firstError ?? ImageUploadIssue.rejected(status).localizedDescription
                    if status == 400 || status == 401 || status == 403 || status >= 500 { break }
                }
            } catch {
                firstError = firstError ?? error.localizedDescription
                break
            }
        }

        var result = "已上传 \(sent) 张。"
        if sent != images.count {
            result += "\(images.count - sent) 张待传。\(firstError ?? "")"
        }
        if importFailures > 0 {
            result += "\(importFailures) 张未能读取。\(importError ?? "")"
        }
        message = result
    }
}
