import Combine
import CryptoKit
import Foundation

enum FileReceiveStatus {
    case idle
    case preparing
    case receiving(name: String, bytes: Int64, total: Int64)
    case finished(name: String)
    case failed(message: String)
}

@MainActor
final class FileReceiveModel: ObservableObject {
    @Published private(set) var status = FileReceiveStatus.idle
    private var link: RelayQRLink?
    private var transfer: FileReceiveTransfer?

    var isReceiving: Bool {
        switch status {
        case .preparing, .receiving:
            return true
        default:
            return false
        }
    }

    var canRetry: Bool {
        if case .failed = status { return link != nil }
        return false
    }

    func receive(scannedValue: String) {
        guard !isReceiving else { return }
        guard let scanned = RelayQRLink(scannedValue: scannedValue, host: "download", requiresEncodedOrigin: true) else {
            link = nil
            status = .failed(message: FileReceiveError.invalidQR.localizedDescription)
            return
        }
        link = scanned
        start(scanned)
    }

    func retry() {
        guard canRetry, let link else { return }
        start(link)
    }

    private func start(_ link: RelayQRLink) {
        status = .preparing
        let transfer = FileReceiveTransfer(link: link) { [weak self] status in
            DispatchQueue.main.async {
                self?.status = status
            }
        } onComplete: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.transfer = nil
                switch result {
                case .success(let file):
                    self.link = nil
                    self.status = .finished(name: file.lastPathComponent)
                case .failure(let error):
                    if let failure = error as? FileReceiveError {
                        if !failure.canRetry { self.link = nil }
                        self.status = .failed(message: failure.localizedDescription)
                    } else {
                        self.status = .failed(message: "接收中断。请确认电脑接收端正在运行，再重试。")
                    }
                }
            }
        }
        self.transfer = transfer
        transfer.start()
    }
}

private enum FileReceiveError: LocalizedError, Equatable {
    case invalidQR
    case expired
    case unsupported
    case invalidResponse
    case server(Int)
    case storage

    var errorDescription: String? {
        switch self {
        case .invalidQR:
            return "请扫描电脑接收端生成的文件分享二维码。"
        case .expired:
            return "文件分享已失效或源文件已更改。请在电脑上重新分享。"
        case .unsupported:
            return "电脑端找不到此文件分享。请确认接收端版本并重新分享。"
        case .invalidResponse:
            return "电脑端返回的文件信息无法验证。"
        case .server(let status):
            return "电脑端返回 HTTP \(status)。"
        case .storage:
            return "无法保存到此 iPhone。请检查可用存储空间后重试。"
        }
    }

    var canRetry: Bool {
        switch self {
        case .invalidQR, .expired, .unsupported:
            return false
        default:
            return true
        }
    }
}

private struct FileReceiveMetadata {
    let filename: String
    let total: Int64
    let etag: String

    init(response: HTTPURLResponse) throws {
        guard let filename = Self.filename(in: response),
              let total = Self.contentLength(in: response),
              let etag = response.value(forHTTPHeaderField: "ETag"),
              etag.utf8.count > 2, etag.first == "\"", etag.last == "\"",
              etag.utf8.dropFirst().dropLast().allSatisfy({ $0 == 33 || (35...126).contains($0) }),
              Self.identityEncoding(response) else {
            throw FileReceiveError.invalidResponse
        }
        self.filename = filename
        self.total = total
        self.etag = etag
    }

    func responseStart(_ response: HTTPURLResponse, requestedOffset: Int64) throws -> Int64 {
        guard Self.filename(in: response) == filename, Self.identityEncoding(response),
              response.value(forHTTPHeaderField: "ETag") == etag else {
            throw FileReceiveError.invalidResponse
        }
        switch response.statusCode {
        case 200:
            guard Self.contentLength(in: response) == total,
                  response.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw FileReceiveError.invalidResponse
            }
            return 0
        case 206:
            let expected = "bytes \(requestedOffset)-\(total - 1)/\(total)"
            guard requestedOffset > 0, requestedOffset < total,
                  response.value(forHTTPHeaderField: "Content-Range") == expected,
                  Self.contentLength(in: response) == total - requestedOffset else {
                throw FileReceiveError.invalidResponse
            }
            return requestedOffset
        default:
            throw FileReceiveError.server(response.statusCode)
        }
    }

    private static func filename(in response: HTTPURLResponse) -> String? {
        guard let encoded = response.value(forHTTPHeaderField: "X-Filename"),
              let decoded = encoded.removingPercentEncoding, !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    private static func contentLength(in response: HTTPURLResponse) -> Int64? {
        guard let length = response.value(forHTTPHeaderField: "Content-Length"), !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(length)
    }

    private static func identityEncoding(_ response: HTTPURLResponse) -> Bool {
        guard let encoding = response.value(forHTTPHeaderField: "Content-Encoding") else { return true }
        return encoding.caseInsensitiveCompare("identity") == .orderedSame
    }
}

private final class FileReceiveTransfer: RefuseRedirects, URLSessionDataDelegate, @unchecked Sendable {
    private let link: RelayQRLink
    private let onProgress: (FileReceiveStatus) -> Void
    private let onComplete: (Result<URL, Error>) -> Void

    // All transfer state is updated on URLSession's serial delegate queue after start().
    private var metadata: FileReceiveMetadata?
    private var partURL: URL?
    private var output: OutputStream?
    private var bytesReceived: Int64 = 0
    private var responseError: Error?
    private var lastProgress = Date.distantPast

    init(
        link: RelayQRLink,
        onProgress: @escaping (FileReceiveStatus) -> Void,
        onComplete: @escaping (Result<URL, Error>) -> Void
    ) {
        self.link = link
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func start() {
        let session = URLSession(
            configuration: directReceiverConfiguration(idleTimeout: 60),
            delegate: self,
            delegateQueue: nil
        )
        var request = requestForDownload(method: "HEAD")
        request.timeoutInterval = 12
        session.dataTask(with: request).resume()
    }

    private func requestForDownload(method: String) -> URLRequest {
        var request = URLRequest(url: ReceiverSettings.endpoint("download", at: link.baseURL))
        request.httpMethod = method
        request.setValue("Bearer \(link.code)", forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let response = response as? HTTPURLResponse else { throw FileReceiveError.invalidResponse }
            switch response.statusCode {
            case 401, 410: throw FileReceiveError.expired
            case 404: throw FileReceiveError.unsupported
            default: break
            }

            if dataTask.originalRequest?.httpMethod == "HEAD" {
                guard response.statusCode == 200 else { throw FileReceiveError.server(response.statusCode) }
                metadata = try FileReceiveMetadata(response: response)
            } else {
                guard let metadata, let partURL else { throw FileReceiveError.invalidResponse }
                bytesReceived = try metadata.responseStart(response, requestedOffset: bytesReceived)
                guard let stream = OutputStream(url: partURL, append: bytesReceived > 0) else {
                    throw FileReceiveError.storage
                }
                stream.open()
                guard stream.streamStatus != .error else { throw FileReceiveError.storage }
                output = stream
                reportProgress(metadata)
            }
            completionHandler(.allow)
        } catch {
            responseError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let metadata, let output, responseError == nil else { return }
        do {
            guard Int64(data.count) <= metadata.total - bytesReceived else {
                throw FileReceiveError.invalidResponse
            }
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard var pointer = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = bytes.count
                while remaining > 0 {
                    let written = output.write(pointer, maxLength: remaining)
                    guard written > 0 else { throw FileReceiveError.storage }
                    pointer += written
                    remaining -= written
                }
            }
            bytesReceived += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) >= 0.2 || bytesReceived == metadata.total {
                reportProgress(metadata)
            }
        } catch {
            responseError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        output?.close()
        output = nil
        if let error = responseError ?? error {
            if (error as? FileReceiveError) == .expired {
                try? FileManager.default.removeItem(at: shareDirectory)
            }
            finish(.failure(error), with: session)
            return
        }
        guard let metadata else {
            finish(.failure(FileReceiveError.invalidResponse), with: session)
            return
        }

        do {
            if task.originalRequest?.httpMethod == "HEAD" {
                try prepareDownload(metadata, session: session)
            } else {
                guard bytesReceived == metadata.total else { throw FileReceiveError.invalidResponse }
                try publishDownload(metadata, session: session)
            }
        } catch {
            finish(.failure(error as? FileReceiveError ?? .storage), with: session)
        }
    }

    private func reportProgress(_ metadata: FileReceiveMetadata) {
        lastProgress = Date()
        onProgress(.receiving(name: metadata.filename, bytes: bytesReceived, total: metadata.total))
    }

    private func prepareDownload(_ metadata: FileReceiveMetadata, session: URLSession) throws {
        let files = FileManager.default
        let root = shareDirectory.deletingLastPathComponent()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        removeStalePartials(in: root)
        try files.createDirectory(at: shareDirectory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])

        let partial = shareDirectory.appendingPathComponent(Self.digest(metadata.etag) + ".part")
        if let oldFiles = try? files.contentsOfDirectory(at: shareDirectory, includingPropertiesForKeys: nil) {
            for old in oldFiles where old != partial {
                try? files.removeItem(at: old)
            }
        }
        partURL = partial
        if files.fileExists(atPath: partial.path) {
            let size = Int64(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if size > metadata.total {
                try files.removeItem(at: partial)
            } else {
                bytesReceived = size
            }
        }

        if bytesReceived == metadata.total && bytesReceived > 0 {
            try publishDownload(metadata, session: session)
            return
        }
        reportProgress(metadata)
        var request = requestForDownload(method: "GET")
        if bytesReceived > 0 {
            request.setValue("bytes=\(bytesReceived)-", forHTTPHeaderField: "Range")
            request.setValue(metadata.etag, forHTTPHeaderField: "If-Range")
        }
        session.dataTask(with: request).resume()
    }

    private func publishDownload(_ metadata: FileReceiveMetadata, session: URLSession) throws {
        guard let partURL, let size = try partURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == metadata.total else {
            throw FileReceiveError.storage
        }
        let files = FileManager.default
        let documents = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let name = Self.safeFilename(metadata.filename)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for index in 0...9999 {
            let suffix = index == 0 ? "" : " (\(index))"
            let candidate = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let destination = documents.appendingPathComponent(candidate, isDirectory: false)
            if files.fileExists(atPath: destination.path) { continue }
            do {
                try files.moveItem(at: partURL, to: destination)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            try? files.removeItem(at: shareDirectory)
            finish(.success(destination), with: session)
            return
        }
        throw FileReceiveError.storage
    }

    private func finish(_ result: Result<URL, Error>, with session: URLSession) {
        session.finishTasksAndInvalidate()
        onComplete(result)
    }

    private var shareDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let identifier = Self.digest(link.baseURL.absoluteString + "\n" + link.code)
        return caches.appendingPathComponent("ScreenRelayDownloads", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    private func removeStalePartials(in root: URL) {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        if let directories = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for directory in directories where directory != shareDirectory {
                if let modified = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified < cutoff {
                    try? files.removeItem(at: directory)
                }
            }
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFilename(_ filename: String) -> String {
        let separators = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var value = filename.components(separatedBy: separators).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.first == "." { value.removeFirst() }
        if value.isEmpty { return "接收文件" }
        let ext = (value as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 32 ? "." + ext : ""
        var stem = suffix.isEmpty ? value : (value as NSString).deletingPathExtension
        while stem.utf8.count + suffix.utf8.count > 200 { stem.removeLast() }
        return (stem.isEmpty ? "接收文件" : stem) + suffix
    }
}
