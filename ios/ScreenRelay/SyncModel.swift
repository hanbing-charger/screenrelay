import Combine
import Foundation
import UIKit

private struct SavedState: Codable {
    var installationID = UUID().uuidString
    var settings: ReceiverSettings? = nil
}

@MainActor
final class SyncModel: ObservableObject {
    static let shared = SyncModel()

    @Published private var state = SavedState()
    @Published private(set) var pairingStatus: String?
    var settings: ReceiverSettings? { state.settings }

    private let receiver = Receiver()
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenRelay", isDirectory: true)
    private var stateURL: URL { support.appendingPathComponent("state.json") }
    private var loaded = false

    private init() {
        load()
    }

    private func load() {
        guard !loaded else { return }
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            var directory = support
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
            }
            // The old capture scanner kept temporary copies here. Picked photos use a separate queue.
            try? FileManager.default.removeItem(at: support.appendingPathComponent("staging", isDirectory: true))
            loaded = true
        } catch {
            pairingStatus = "无法打开本机配对记录。\(error.localizedDescription)"
        }
    }

    private func save(_ next: SavedState) throws {
        try JSONEncoder().encode(next).write(to: stateURL, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication
        ])
        state = next
    }

    func saveSettings(address: String, token: String) {
        load()
        guard loaded else { return }
        do {
            try applySettings(ReceiverSettings(address: address, token: token))
            pairingStatus = "已保存配对。"
        } catch {
            pairingStatus = error.localizedDescription
        }
    }

    func pair(scannedValue: String) async throws -> ReceiverSettings {
        let link = try PairingLink(scannedValue: scannedValue)
        load()
        guard loaded else { throw ReceiverIssue.unavailableStorage }
        if !FileManager.default.fileExists(atPath: stateURL.path) {
            try save(state)
        }

        var deviceName = UIDevice.current.name.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while deviceName.unicodeScalars.count > 80 {
            deviceName.removeLast()
        }
        let settings = try await receiver.pair(link, deviceID: state.installationID,
                                               deviceName: deviceName.isEmpty ? "iPhone" : deviceName)
        try applySettings(settings)
        return settings
    }

    private func applySettings(_ settings: ReceiverSettings) throws {
        guard settings != state.settings else { return }
        var next = state
        next.settings = settings
        try save(next)
    }

    func testSettings(address: String, token: String) async -> String {
        do {
            let candidate = try ReceiverSettings(address: address, token: token)
            try await receiver.test(candidate)
            return "已连通电脑，配对凭据将在首次上传时验证。"
        } catch {
            return "连接测试失败。\(error.localizedDescription)"
        }
    }

    func sendDiagnostic(_ record: DiagnosticRecord, to settings: ReceiverSettings) async throws -> Int {
        guard self.settings == settings else { throw DiagnosticUploadIssue.settingsChanged }
        return try await receiver.uploadDiagnostic(record, settings: settings, installationID: state.installationID)
    }

    func sendPickedFile(_ item: PendingUpload, file: URL, to settings: ReceiverSettings) async throws -> Int {
        guard self.settings == settings else { throw UploadIssue.pairingChanged }
        return try await receiver.uploadPickedFile(item, file: file, settings: settings, installationID: state.installationID)
    }
}
