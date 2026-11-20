import CryptoKit
import Foundation

struct ReceiverSettings: Codable, Equatable {
    let baseURL: URL
    let token: String

    init(address: String, token: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ReceiverIssue.token
        }
        components.scheme = scheme
        components.path = ""
        guard let baseURL = components.url else { throw ReceiverIssue.address }
        self.baseURL = baseURL
        self.token = token
    }

    func endpoint(_ name: String) -> URL {
        baseURL.appendingPathComponent("api").appendingPathComponent("v1").appendingPathComponent(name)
    }
}

enum ReceiverIssue: LocalizedError {
    case address
    case token
    case response(Int?)
    case unexpectedResponse
    case emptyFile

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
        case .emptyFile:
            return "相册导出的文件为空。"
        }
    }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
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

final class Receiver {
    private struct Health: Decodable {
        let status: String
    }

    private struct Receipt: Decodable {
        let id: String
    }

    private let session: URLSession
    private let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 30 * 60
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    func test(_ settings: ReceiverSettings) async throws {
        var request = URLRequest(url: settings.endpoint("health"))
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode
        guard code == 200 else { throw ReceiverIssue.response(code) }
        guard (try? JSONDecoder().decode(Health.self, from: data))?.status == "ok" else {
            throw ReceiverIssue.unexpectedResponse
        }
    }

    func upload(_ capture: Capture, file: URL, settings: ReceiverSettings, installationID: String) async throws -> Int {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ReceiverIssue.emptyFile }
        let identifier = SHA256.hash(data: Data("\(installationID):\(capture.localIdentifier)".utf8))
            .map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: settings.endpoint("uploads"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue(capture.filename.addingPercentEncoding(withAllowedCharacters: unreserved),
                         forHTTPHeaderField: "X-Filename")
        request.setValue(capture.kind.rawValue, forHTTPHeaderField: "X-Media-Kind")
        request.setValue(identifier, forHTTPHeaderField: "X-Upload-Id")
        request.setValue(capture.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let response = response as? HTTPURLResponse else { throw ReceiverIssue.response(nil) }
        if response.statusCode == 200 || response.statusCode == 201 {
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data), !receipt.id.isEmpty else {
                throw ReceiverIssue.unexpectedResponse
            }
        }
        return response.statusCode
    }
}
