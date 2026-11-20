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
        let base64URLCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard let components = URLComponents(string: scannedValue),
              components.scheme == "screenrelay", components.host == "pair", components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 3,
              items.first(where: { $0.name == "v" })?.value == "1",
              let address = items.first(where: { $0.name == "url" })?.value,
              let baseURL = try? ReceiverSettings.validatedBaseURL(address),
              let code = items.first(where: { $0.name == "code" })?.value, code.utf8.count == 43,
              code.unicodeScalars.allSatisfy(base64URLCharacters.contains) else {
            throw ReceiverIssue.invalidPairingQR
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

    private struct PairingRequest: Encodable {
        let pairingCode: String
        let deviceId: String
        let deviceName: String
    }

    private struct PairingResponse: Decodable {
        let token: String
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

    func pair(_ link: PairingLink, deviceID: String, deviceName: String) async throws -> ReceiverSettings {
        var request = URLRequest(url: ReceiverSettings.endpoint("pair", at: link.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairingRequest(
            pairingCode: link.code, deviceId: deviceID, deviceName: deviceName
        ))

        let (data, response) = try await session.data(for: request)
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
