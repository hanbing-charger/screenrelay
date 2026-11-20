import CryptoKit
import Foundation

struct ReceiverSettings: Codable, Equatable {
    let baseURL: URL
    let token: String

    init(address: String, token: String) throws {
        baseURL = try Self.validatedBaseURL(address)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ReceiverIssue.token
        }
        self.token = token
    }

    static func validatedBaseURL(_ address: String) throws -> URL {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path == "" || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ReceiverIssue.address
        }
        components.scheme = scheme
        components.path = ""
        guard let baseURL = components.url else { throw ReceiverIssue.address }
        return baseURL
    }

    func endpoint(_ name: String) -> URL {
        Self.endpoint(name, at: baseURL)
    }

    static func endpoint(_ name: String, at baseURL: URL) -> URL {
        baseURL.appendingPathComponent("api").appendingPathComponent("v1").appendingPathComponent(name)
    }
}

struct PairingLink {
    let baseURL: URL
    let code: String

    init(scannedValue: String) throws {
        guard let link = RelayQRLink(scannedValue: scannedValue, host: "pair") else {
            throw ReceiverIssue.invalidPairingQR
        }
        self.baseURL = link.baseURL
        self.code = link.code
    }
}

struct RelayQRLink {
    let baseURL: URL
    let code: String

    init?(scannedValue: String, host: String, requiresEncodedOrigin: Bool = false) {
        let base64URLCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard let components = URLComponents(string: scannedValue),
              components.scheme == "screenrelay", components.host == host, components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 3,
              items.first(where: { $0.name == "v" })?.value == "1",
              let address = items.first(where: { $0.name == "url" })?.value,
              let baseURL = try? ReceiverSettings.validatedBaseURL(address),
              let code = items.first(where: { $0.name == "code" })?.value, code.utf8.count == 43,
              code.unicodeScalars.allSatisfy(base64URLCharacters.contains) else {
            return nil
        }
        if requiresEncodedOrigin {
            let allowed = base64URLCharacters.union(CharacterSet(charactersIn: ".~%"))
            guard let encoded = components.percentEncodedQueryItems?.first(where: { $0.name == "url" })?.value,
                  encoded.unicodeScalars.allSatisfy(allowed.contains),
                  encoded.removingPercentEncoding == address, address == address.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
        }
        self.baseURL = baseURL
        self.code = code
    }
}

enum ReceiverIssue: LocalizedError {
    case address
    case token
    case response(Int?)
    case unexpectedResponse
    case invalidPairingQR
    case expiredPairingCode
    case unavailableStorage
    case emptyFile
    case invalidDiagnosticSize

    var errorDescription: String? {
        switch self {
        case .address:
            return "请输入电脑端显示的完整地址，例如 http://192.168.1.20:8765。"
        case .token:
            return "请输入电脑端显示的配对码。"
        case .response(let code):
            return code.map { "电脑端返回 HTTP \($0)。" } ?? "未收到电脑端的 HTTP 响应。"
        case .unexpectedResponse:
            return "此地址的响应与截屏快传接收端不符。"
        case .invalidPairingQR:
            return "无法识别此二维码。请扫描截屏快传电脑端的配对二维码。"
        case .expiredPairingCode:
            return "配对二维码已失效，请在电脑上生成新的二维码后重试。"
        case .unavailableStorage:
            return "无法打开本机同步记录。"
        case .emptyFile:
            return "相册导出的文件为空。"
        case .invalidDiagnosticSize:
            return "诊断日志为空或超过 1 MiB。"
        }
    }
}

class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

func directReceiverConfiguration(idleTimeout: TimeInterval) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.allowsCellularAccess = false
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    // Override the system HTTP proxy for this receiver session.
    configuration.connectionProxyDictionary = [
        "HTTPEnable": 0,
        "HTTPSEnable": 0,
        "SOCKSEnable": 0,
        "ProxyAutoConfigEnable": 0,
        "ProxyAutoDiscoveryEnable": 0,
    ]
    configuration.timeoutIntervalForRequest = idleTimeout
    configuration.timeoutIntervalForResource = 45 * 60
    return configuration
}

private final class ReceiverTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func start(_ task: URLSessionTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        task.resume()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

final class Receiver {
    private struct Health: Decodable {
        let status: String
    }

    private struct Receipt: Decodable {
        let id: String
    }

    private struct PairingRequest: Encodable {
        let pairingCode: String
        let deviceId: String
        let deviceName: String
    }

    private struct PairingResponse: Decodable {
        let token: String
    }

    private let session: URLSession
    private static let uploadIdleTimeout: TimeInterval = 90
    private let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    init() {
        let configuration = directReceiverConfiguration(idleTimeout: Self.uploadIdleTimeout)
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    private func send(_ request: URLRequest, uploading file: URL? = nil) async throws -> (Data, URLResponse) {
        let operation = ReceiverTask()
        let result: (Data, URLResponse) = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let complete: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: ReceiverIssue.response(nil))
                    }
                }
                let task: URLSessionTask
                if let file {
                    task = session.uploadTask(with: request, fromFile: file, completionHandler: complete)
                } else {
                    task = session.dataTask(with: request, completionHandler: complete)
                }
                operation.start(task)
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    func test(_ settings: ReceiverSettings) async throws {
        var request = URLRequest(url: settings.endpoint("health"))
        request.timeoutInterval = 8
        let (data, response) = try await send(request)
        let code = (response as? HTTPURLResponse)?.statusCode
        guard code == 200 else { throw ReceiverIssue.response(code) }
        guard (try? JSONDecoder().decode(Health.self, from: data))?.status == "ok" else {
            throw ReceiverIssue.unexpectedResponse
        }
    }

    func pair(_ link: PairingLink, deviceID: String, deviceName: String) async throws -> ReceiverSettings {
        var request = URLRequest(url: ReceiverSettings.endpoint("pair", at: link.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairingRequest(
            pairingCode: link.code, deviceId: deviceID, deviceName: deviceName
        ))

        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { throw ReceiverIssue.expiredPairingCode }
        guard status == 200 || status == 201 else { throw ReceiverIssue.response(status) }
        guard let response = try? JSONDecoder().decode(PairingResponse.self, from: data),
              let settings = try? ReceiverSettings(address: link.baseURL.absoluteString, token: response.token) else {
            throw ReceiverIssue.unexpectedResponse
        }
        return settings
    }

    func upload(_ capture: Capture, file: URL, settings: ReceiverSettings, installationID: String) async throws -> Int {
        let identifier = SHA256.hash(data: Data("\(installationID):\(capture.localIdentifier)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return try await uploadFile(file, filename: capture.filename, kind: capture.kind.rawValue,
                                    contentType: capture.mimeType, identifier: identifier, settings: settings)
    }

    func uploadDiagnostic(_ record: DiagnosticRecord, settings: ReceiverSettings, installationID: String) async throws -> Int {
        let identifier = DiagnosticsStore.digest(Data("\(installationID):diagnostic:\(record.id)".utf8))
        return try await uploadFile(record.file, filename: record.file.lastPathComponent, kind: "diagnostic",
                                    contentType: "text/plain; charset=utf-8", identifier: identifier, settings: settings,
                                    sizeLimit: DiagnosticRecord.maxBytes)
    }

    private func uploadFile(
        _ file: URL, filename: String, kind: String, contentType: String, identifier: String,
        settings: ReceiverSettings, sizeLimit: Int? = nil
    ) async throws -> Int {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let sizeLimit, size <= 0 || size > sizeLimit { throw ReceiverIssue.invalidDiagnosticSize }
        guard size > 0 else { throw ReceiverIssue.emptyFile }
        var request = URLRequest(url: settings.endpoint("uploads"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.uploadIdleTimeout
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue(filename.addingPercentEncoding(withAllowedCharacters: unreserved),
                         forHTTPHeaderField: "X-Filename")
        request.setValue(kind, forHTTPHeaderField: "X-Media-Kind")
        request.setValue(identifier, forHTTPHeaderField: "X-Upload-Id")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await send(request, uploading: file)
        guard let response = response as? HTTPURLResponse else { throw ReceiverIssue.response(nil) }
        if response.statusCode == 200 || response.statusCode == 201 {
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data), !receipt.id.isEmpty else {
                throw ReceiverIssue.unexpectedResponse
            }
        }
        return response.statusCode
    }
}
