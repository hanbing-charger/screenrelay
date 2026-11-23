import Combine
import Foundation
import ImageIO
import MobileCoreServices
import Photos
import UniformTypeIdentifiers

enum UploadKind: String, Codable, Sendable {
    case photo
    case video
    case file
}

struct PendingUpload: Codable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let mimeType: String
    let addedAt: Date
    let kind: UploadKind

    private enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, addedAt, kind
    }

    init(filename: String, mimeType: String, kind: UploadKind) {
        id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.kind = kind
        addedAt = Date()
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        filename = try fields.decode(String.self, forKey: .filename)
        mimeType = try fields.decode(String.self, forKey: .mimeType)
        addedAt = try fields.decode(Date.self, forKey: .addedAt)
        kind = try fields.decodeIfPresent(UploadKind.self, forKey: .kind) ?? .photo
    }
}

enum UploadIssue: LocalizedError {
    case unavailable
    case unsupported
    case notRegularFile
    case pairingChanged
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "无法读取所选项目。若保存在 iCloud，请确认文件可访问后重选。"
        case .unsupported:
            return "暂不支持所选媒体格式。可通过「选择文件上传」发送原文件。"
        case .notRegularFile:
            return "请选择文件。文件夹可压缩为文件后上传。"
        case .pairingChanged:
            return "电脑配置已更改。请确认接收电脑后重试待传文件。"
        case .rejected(let code):
            switch code {
            case 400:
                return "电脑端拒绝接收。请确认电脑和手机两端均已更新至 1.0.0 或以上。"
            case 401, 403:
                return "电脑拒绝了配对凭据，请重新配对后重试。"
            case 413:
                return "文件超过电脑端的大小上限。"
            case 415:
                return "电脑端暂不支持此格式。请更新至 1.0.0 或以上，或用「选择文件上传」重选。"
            default:
                return "电脑端返回 HTTP \(code)。"
            }
        }
    }
}

enum UploadSelection {
    case provider(NSItemProvider, UploadKind)
    case document(URL)
    case asset(PHAssetResource)
    case prepared(Result<PendingUpload, Error>)
}

enum UploadStore {
    private static let files = FileManager.default
    // Keep both the directory and payload names used by the original photo queue.
    private static let payloadName = "image"
    private static let photoFormats: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "jpe": "image/jpeg", "jfif": "image/jpeg", "heic": "image/heic",
        "heif": "image/heif", "hif": "image/heif", "bmp": "image/bmp",
        "webp": "image/webp", "avif": "image/avif", "gif": "image/gif",
        "jxl": "image/jxl", "tif": "image/tiff", "tiff": "image/tiff",
        "dng": "image/x-adobe-dng",
    ]
    private static let videoFormats: [String: String] = [
        "mp4": "video/mp4", "mov": "video/quicktime", "m4v": "video/mp4",
        "webm": "video/webm", "mkv": "video/x-matroska",
        "3gp": "video/3gpp", "3gpp": "video/3gpp", "3g2": "video/3gpp2", "3gp2": "video/3gpp2",
        "avi": "video/x-msvideo", "mpeg": "video/mpeg", "mpg": "video/mpeg",
        "mpe": "video/mpeg", "m2v": "video/mpeg", "ts": "video/mp2t",
        "mts": "video/mp2t", "m2ts": "video/mp2t", "wmv": "video/x-ms-wmv",
        "flv": "video/x-flv", "ogv": "video/ogg",
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

    static func restore() throws -> [PendingUpload] {
        let directory = try directory()
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries.compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent) else { return nil }
            let meta = entry.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: meta),
               let item = try? JSONDecoder().decode(PendingUpload.self, from: data),
               item.id == id,
               files.fileExists(atPath: entry.appendingPathComponent(payloadName).path) {
                return item
            }
            return nil
        }.sorted { $0.addedAt < $1.addedAt }
    }

    static func file(for item: PendingUpload) throws -> URL {
        try directory().appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(payloadName)
    }

    static func remove(_ item: PendingUpload) throws {
        try files.removeItem(at: file(for: item).deletingLastPathComponent())
    }

    static func stageMedia(_ source: URL, suggestedName: String?, typeHint: String?, kind: UploadKind) throws -> PendingUpload {
        let name = suggestedName ?? source.lastPathComponent
        let formats = kind == .photo ? photoFormats : videoFormats
        let sourceExtension = source.pathExtension.lowercased()
        let suggestedExtension = (name as NSString).pathExtension.lowercased()
        let extensionGuess = [sourceExtension, suggestedExtension].first { formats[$0] != nil }

        let chosenExtension: String
        if kind == .photo {
            let detectedType = CGImageSourceCreateWithURL(source as CFURL, nil)
                .flatMap { CGImageSourceGetType($0) }.map { $0 as String }
            let typedExtension = preferredExtension(detectedType) ?? preferredExtension(typeHint)
            if extensionGuess == "dng" && (typedExtension == "tiff" || typedExtension == "tif") {
                // DNG is a TIFF-based raw format.
                chosenExtension = "dng"
            } else if let typedExtension {
                guard let mime = formats[typedExtension] else { throw UploadIssue.unsupported }
                chosenExtension = extensionGuess.flatMap { formats[$0] == mime ? $0 : nil } ?? typedExtension
            } else if let extensionGuess {
                chosenExtension = extensionGuess
            } else {
                throw UploadIssue.unsupported
            }
        } else {
            // The representation on disk gives a more precise container than a generic movie UTI.
            guard let suffix = extensionGuess ?? preferredExtension(typeHint) else { throw UploadIssue.unsupported }
            chosenExtension = suffix
        }

        guard let mime = formats[chosenExtension] else { throw UploadIssue.unsupported }
        let filename = normalizedName(name, suffix: chosenExtension, formats: formats, kind: kind)
        return try stage(name: filename, mimeType: mime, kind: kind) { destination in
            try files.copyItem(at: source, to: destination)
        }
    }

    static func stageLegacyJPEG(_ bytes: Data) throws -> PendingUpload {
        try stage(name: "图片.jpg", mimeType: "image/jpeg", kind: .photo) { destination in
            try bytes.write(to: destination, options: [.completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func stageLegacyVideo(_ source: URL, suggestedName: String?) async throws -> PendingUpload {
        try await offMain {
            try stageMedia(source, suggestedName: suggestedName, typeHint: nil, kind: .video)
        }
    }

    static func stageDocument(_ source: URL) async throws -> PendingUpload {
        try await offMain {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            var coordinationError: NSError?
            var staged: Result<PendingUpload, Error>?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                staged = Result {
                    let attributes = try readable.resourceValues(forKeys: [.isRegularFileKey])
                    guard attributes.isRegularFile == true else { throw UploadIssue.notRegularFile }
                    let filename = source.lastPathComponent
                    guard !filename.isEmpty else { throw UploadIssue.unavailable }
                    return try stage(name: filename, mimeType: "application/octet-stream", kind: .file) { destination in
                        try files.copyItem(at: readable, to: destination)
                    }
                }
            }
            guard let staged else {
                if let coordinationError { throw coordinationError }
                throw UploadIssue.unavailable
            }
            return try staged.get()
        }
    }

    static func stage(_ resource: PHAssetResource) async throws -> PendingUpload {
        let file = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        return try stageMedia(file, suggestedName: resource.originalFilename, typeHint: resource.uniformTypeIdentifier, kind: .photo)
    }

    private static func stage(
        name: String, mimeType: String, kind: UploadKind, write: (URL) throws -> Void
    ) throws -> PendingUpload {
        let item = PendingUpload(filename: name, mimeType: mimeType, kind: kind)
        let destination = try file(for: item)
        let folder = destination.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        do {
            try write(destination)
            guard let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 || (kind == .file && size == 0) else { throw UploadIssue.unavailable }
            try files.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("metadata.json"),
                                                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return item
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    @available(iOS 14.0, *)
    static func stage(_ provider: NSItemProvider, kind: UploadKind) async throws -> PendingUpload {
        let formats = kind == .photo ? photoFormats : videoFormats
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.filter { type in
            kind == .photo ? type.conforms(to: .image) : type.conforms(to: .movie) || type.conforms(to: .video)
        }
        let type = types.first { item in
            preferredExtension(item.identifier).map { formats[$0] != nil } ?? false
        } ?? types.first
        guard let type else { throw UploadIssue.unsupported }
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                guard let source else {
                    continuation.resume(throwing: error ?? UploadIssue.unavailable)
                    return
                }
                continuation.resume(with: Result {
                    // The picker-owned file is valid only until this callback returns.
                    try stageMedia(source, suggestedName: name, typeHint: type.identifier, kind: kind)
                })
            }
        }
    }

    private static func offMain(_ operation: @escaping () throws -> PendingUpload) async throws -> PendingUpload {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    private static func preferredExtension(_ type: String?) -> String? {
        guard let type, type != "public.movie", type != "public.video" else { return nil }
        if type == "com.adobe.raw-image" { return "dng" }
        if #available(iOS 14.0, *), let ext = UTType(type)?.preferredFilenameExtension {
            return ext.lowercased()
        }
        guard let ext = UTTypeCopyPreferredTagWithClass(type as CFString, kUTTagClassFilenameExtension) else {
            return nil
        }
        return (ext.takeRetainedValue() as String).lowercased()
    }

    private static func normalizedName(
        _ name: String, suffix ext: String, formats: [String: String], kind: UploadKind
    ) -> String {
        let separators = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let clean = name.components(separatedBy: separators).joined(separator: "_")
        let originalExt = (clean as NSString).pathExtension
        var stem = formats[originalExt.lowercased()] == nil ? clean : (clean as NSString).deletingPathExtension
        stem = stem.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while stem.utf8.count > 180 { stem.removeLast() }
        let suffix = originalExt.lowercased() == ext ? originalExt : ext
        let fallback = kind == .photo ? "图片" : "视频"
        return (stem.isEmpty ? fallback : stem) + "." + suffix
    }
}

@MainActor
final class ManualUploadModel: ObservableObject {
    @Published private(set) var pending: [PendingUpload] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    init() {
        do {
            pending = try UploadStore.restore()
        } catch {
            message = "无法读取待传文件。"
        }
    }

    func accept(_ selection: [UploadSelection], sync: SyncModel) {
        guard !busy, !selection.isEmpty else { return }
        busy = true
        message = "正在读取所选项目…"
        let settings = sync.settings
        Task {
            defer { busy = false }
            var prepared: [PendingUpload] = []
            var importFailures = 0
            var importError: String?
            for source in selection {
                do {
                    let item: PendingUpload
                    switch source {
                    case .provider(let provider, let kind):
                        if #available(iOS 14, *) {
                            item = try await UploadStore.stage(provider, kind: kind)
                        } else {
                            throw UploadIssue.unavailable
                        }
                    case .document(let url):
                        item = try await UploadStore.stageDocument(url)
                    case .prepared(let result):
                        item = try result.get()
                    case .asset(let resource):
                        item = try await UploadStore.stage(resource)
                    }
                    pending.append(item)
                    prepared.append(item)
                } catch {
                    importFailures += 1
                    importError = importError ?? error.localizedDescription
                }
            }
            if let settings {
                await upload(prepared, to: settings, sync: sync, importFailures: importFailures, importError: importError)
            } else if prepared.isEmpty {
                message = importError ?? UploadIssue.unavailable.localizedDescription
            } else {
                message = "\(prepared.count) 项已加入待传。请先配对电脑再重试。"
                if importFailures > 0 {
                    message = (message ?? "") + "\(importFailures) 项未能读取。\(importError ?? "")"
                }
            }
        }
    }

    func retry(sync: SyncModel) {
        guard !busy, !pending.isEmpty, let settings = sync.settings else { return }
        let items = pending
        busy = true
        Task {
            defer { busy = false }
            await upload(items, to: settings, sync: sync, importFailures: 0, importError: nil)
        }
    }

    func discardPending() {
        guard !busy else { return }
        var remaining: [PendingUpload] = []
        for item in pending {
            do {
                try UploadStore.remove(item)
            } catch {
                remaining.append(item)
            }
        }
        pending = remaining
        message = pending.isEmpty ? "已清除待传副本。" : "有待传副本未能清除。"
    }

    private func upload(
        _ items: [PendingUpload], to settings: ReceiverSettings, sync: SyncModel,
        importFailures: Int, importError: String?
    ) async {
        var sent = 0
        var firstError: String?
        for item in items {
            message = "正在上传 \(item.filename)"
            do {
                let file = try UploadStore.file(for: item)
                let status = try await sync.sendPickedFile(item, file: file, to: settings)
                if status == 200 || status == 201 {
                    try UploadStore.remove(item)
                    pending.removeAll { $0.id == item.id }
                    sent += 1
                } else {
                    firstError = firstError ?? UploadIssue.rejected(status).localizedDescription
                    if status == 400 || status == 401 || status == 403 || status >= 500 { break }
                }
            } catch {
                firstError = firstError ?? error.localizedDescription
                break
            }
        }

        var result = "已上传 \(sent) 项。"
        if sent != items.count {
            result += "\(items.count - sent) 项待传。\(firstError ?? "")"
        }
        if importFailures > 0 {
            result += "\(importFailures) 项未能读取。\(importError ?? "")"
        }
        message = result
    }
}
