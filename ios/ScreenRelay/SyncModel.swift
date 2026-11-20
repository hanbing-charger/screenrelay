import BackgroundTasks
import Combine
import Foundation
import Photos
import SwiftUI
import UIKit

private struct SavedState: Codable {
    var installationID = UUID().uuidString
    var settings: ReceiverSettings? = nil
    var enabled = false
    var captureFrom: Date? = nil
    var uploaded: Set<String> = []
    var failed: [String: String] = [:]
}

@MainActor
final class SyncModel: ObservableObject {
    static let shared = SyncModel()
    static var processingID: String {
        (Bundle.main.bundleIdentifier ?? "com.screenrelay.sender") + ".scan"
    }

    @Published private var state = SavedState()
    @Published private(set) var permission = LibraryPermission.current()
    @Published private(set) var lastStatus = "请先配对电脑。"
    @Published private(set) var pending = 0
    @Published private(set) var running = false

    var settings: ReceiverSettings? { state.settings }
    var enabled: Bool { state.enabled }
    var uploadedCount: Int { state.uploaded.count }
    var failureMessages: [String] { state.failed.values.sorted() }

    private let receiver = Receiver()
    private let observer = LibraryObserver()
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenRelay", isDirectory: true)
    private var stateURL: URL { support.appendingPathComponent("state.json") }
    private var staging: URL { support.appendingPathComponent("staging", isDirectory: true) }
    private var loaded = false
    private var observing = false
    private var inForeground = false
    private var backgroundGrace = UIBackgroundTaskIdentifier.invalid
    private var scanTask: Task<Void, Never>?
    private var scanAgain = false
    private var retryAfter: Date?

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
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            loaded = true
            if state.settings != nil {
                lastStatus = "已保存电脑配置。"
            }
        } catch {
            lastStatus = "无法打开本机同步记录。\(error.localizedDescription)"
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
        } catch {
            lastStatus = error.localizedDescription
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

    private func applySettings(_ nextSettings: ReceiverSettings) throws {
        guard nextSettings != settings else {
            lastStatus = "已保存电脑配置。"
            return
        }
        var next = state
        next.settings = nextSettings
        next.failed.removeAll()
        try save(next)
        scanTask?.cancel()
        retryAfter = nil
        lastStatus = "已保存电脑配置。"
        startScan()
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

    func setEnabled(_ enabled: Bool) {
        load()
        guard loaded, state.settings != nil else { return }
        do {
            var next = state
            next.enabled = enabled
            if enabled && next.captureFrom == nil {
                next.captureFrom = Date()
            }
            try save(next)
            if enabled {
                retryAfter = nil
                scheduleBackground()
                if permission == .notDetermined {
                    Task { await requestPermission() }
                } else {
                    startScan()
                }
            } else {
                scanTask?.cancel()
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
                lastStatus = "自动上传已暂停。"
            }
        } catch {
            lastStatus = "无法保存同步设置。\(error.localizedDescription)"
        }
    }

    func requestPermission() async {
        await LibraryPermission.request()
        refreshPermission()
        startScan()
    }

    private func refreshPermission() {
        permission = LibraryPermission.current()
        let canRead = permission == .authorized || permission == .limited
        if canRead && !observing {
            PHPhotoLibrary.shared().register(observer)
            observing = true
        } else if !canRead && observing {
            PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            observing = false
        }
    }

    func becameActive() {
        inForeground = true
        load()
        refreshPermission()
        startScan()
    }

    func enteredBackground() {
        inForeground = false
        scheduleBackground()
        guard enabled, backgroundGrace == .invalid else { return }
        backgroundGrace = UIApplication.shared.beginBackgroundTask(withName: "Finish capture transfer") {
            Task { @MainActor in
                self.scanTask?.cancel()
                self.endBackgroundGrace()
            }
        }
        if startScan() == nil { endBackgroundGrace() }
    }

    private func endBackgroundGrace() {
        guard backgroundGrace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundGrace)
        backgroundGrace = .invalid
    }

    func libraryChanged() {
        if inForeground || backgroundGrace != .invalid { startScan() }
    }

    func foregroundTick() {
        if inForeground { startScan() }
    }

    func syncNow() {
        retryAfter = nil
        refreshPermission()
        startScan()
    }

    func retryFailures() {
        do {
            var next = state
            next.failed.removeAll()
            try save(next)
            syncNow()
        } catch {
            lastStatus = "无法更新失败记录。\(error.localizedDescription)"
        }
    }

    private func scheduleBackground() {
        guard enabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Foreground discovery remains available when iOS declines background scheduling.
        }
    }

    func runBackground(_ task: BGProcessingTask) async {
        load()
        refreshPermission()
        scheduleBackground()
        let work = startScan()
        var completed = false
        task.expirationHandler = { [weak task] in
            work?.cancel()
            Task { @MainActor in
                guard !completed else { return }
                completed = true
                task?.expirationHandler = nil
                task?.setTaskCompleted(success: false)
            }
        }
        await work?.value
        guard !completed else { return }
        completed = true
        task.expirationHandler = nil
        task.setTaskCompleted(success: work?.isCancelled != true)
    }

    @discardableResult
    private func startScan() -> Task<Void, Never>? {
        guard loaded, enabled, let settings, let captureFrom = state.captureFrom else { return nil }
        if let retryAfter, retryAfter > Date() { return nil }
        if let scanTask {
            scanAgain = true
            return scanTask
        }
        guard permission == .authorized || permission == .limited else {
            lastStatus = "请允许读取相册以发现新的截屏和录屏。"
            return nil
        }
        running = true
        let task = Task {
            await self.scan(settings: settings, captureFrom: captureFrom)
            self.scanTask = nil
            self.running = false
            let scanAgain = self.scanAgain
            self.scanAgain = false
            if scanAgain && (self.inForeground || self.backgroundGrace != .invalid) && self.startScan() != nil {
                return
            }
            self.endBackgroundGrace()
        }
        scanTask = task
        return task
    }

    private func scan(settings: ReceiverSettings, captureFrom: Date) async {
        let processed = state.uploaded.union(state.failed.keys)
        let captures = CaptureLibrary.find(since: captureFrom, excluding: processed)
        pending = captures.count
        if captures.isEmpty {
            lastStatus = state.failed.isEmpty ? "正在等待新的截屏和录屏。" : "部分文件上传失败，请查看失败记录。"
            return
        }

        for capture in captures {
            guard !Task.isCancelled, enabled, self.settings == settings else { return }
            let file = staging.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }

            do {
                try await capture.export(to: file)
            } catch {
                guard !Task.isCancelled else { return }
                lastStatus = "暂时无法读取 \(capture.filename)。\(error.localizedDescription)"
                continue
            }

            guard !Task.isCancelled, enabled, self.settings == settings else { return }
            lastStatus = "正在上传 \(capture.filename)"
            do {
                let status = try await receiver.upload(capture, file: file, settings: settings,
                                                       installationID: state.installationID)
                guard !Task.isCancelled, enabled, self.settings == settings else { return }

                var next = state
                switch status {
                case 200, 201:
                    next.uploaded.insert(capture.localIdentifier)
                    try save(next)
                    pending -= 1
                    lastStatus = "已上传 \(capture.filename)"
                case 409, 413, 415, 422:
                    let detail = status == 413 ? "超过电脑端文件大小限制" : "电脑端拒收（HTTP \(status)）"
                    next.failed[capture.localIdentifier] = "\(capture.filename) · \(detail)"
                    try save(next)
                    pending -= 1
                    lastStatus = detail
                case 401, 403:
                    retryAfter = Date().addingTimeInterval(60)
                    lastStatus = "配对凭据无效，请重新扫码配对或核对手动配对码。"
                    return
                default:
                    retryAfter = Date().addingTimeInterval(30)
                    lastStatus = ReceiverIssue.response(status).localizedDescription
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                retryAfter = Date().addingTimeInterval(30)
                lastStatus = "上传暂未完成，稍后会重试。\(error.localizedDescription)"
                return
            }
        }
    }
}
