import CryptoKit
import Foundation
import MetricKit

enum DiagnosticKind: String {
    case crash
    case hang

    var title: String { self == .crash ? "崩溃" : "卡顿" }
}

struct DiagnosticRecord: Identifiable {
    static let maxBytes = 1024 * 1024
    let id: String
    let kind: DiagnosticKind
    let windowEnd: Date
    let file: URL
}

struct DiagnosticSnapshot {
    let records: [DiagnosticRecord]
    let uploaded: Set<String>
}

private struct DiagnosticDraft {
    let id: String
    let content: Data
}

final class DiagnosticsStore: @unchecked Sendable {
    static let shared = DiagnosticsStore()
    static let changed = Notification.Name("ScreenRelayDiagnosticsChanged")
    private static let retention: TimeInterval = 24 * 60 * 60
    private let queue = DispatchQueue(label: "com.screenrelay.diagnostics.store", qos: .utility)
    private let files = FileManager.default

    private init() {}

    private func directory() throws -> URL {
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        var directory = support.appendingPathComponent("ScreenRelayDiagnostics", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        return directory
    }

    fileprivate func save(_ drafts: [DiagnosticDraft]) {
        queue.async {
            guard let directory = try? self.directory() else { return }
            _ = try? self.recentRecords(in: directory)
            var changed = false
            for draft in drafts {
                guard draft.content.count <= DiagnosticRecord.maxBytes else { continue }
                let file = directory.appendingPathComponent(draft.id + ".txt")
                guard !self.files.fileExists(atPath: file.path) else { continue }
                do {
                    try draft.content.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    changed = true
                } catch {
                    continue
                }
            }
            if changed {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                }
            }
        }
    }

    func snapshot(for receiver: URL?, completion: @escaping (Result<DiagnosticSnapshot, Error>) -> Void) {
        queue.async {
            let result = Result {
                let directory = try self.directory()
                let records = try self.recentRecords(in: directory)
                let retainedIDs = Set(records.map(\.id))
                let uploadedFile = directory.appendingPathComponent("uploaded.json")
                let previous = self.readUploaded(at: uploadedFile)
                let uploaded = previous.mapValues { $0.intersection(retainedIDs) }.filter { !$0.value.isEmpty }
                if uploaded != previous {
                    try? self.writeUploaded(uploaded, to: uploadedFile)
                }
                let receiverKey = receiver.map { Self.digest(Data($0.absoluteString.utf8)) }
                return DiagnosticSnapshot(records: records, uploaded: receiverKey.flatMap { uploaded[$0] } ?? [])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func markUploaded(_ id: String, to receiver: URL) {
        queue.async {
            guard let directory = try? self.directory() else { return }
            let uploadedFile = directory.appendingPathComponent("uploaded.json")
            var uploaded = self.readUploaded(at: uploadedFile)
            let key = Self.digest(Data(receiver.absoluteString.utf8))
            uploaded[key, default: []].insert(id)
            try? self.writeUploaded(uploaded, to: uploadedFile)
        }
    }

    private func recentRecords(in directory: URL) throws -> [DiagnosticRecord] {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var records: [DiagnosticRecord] = []
        for file in entries where file.pathExtension == "txt" {
            let id = file.deletingPathExtension().lastPathComponent
            let parts = id.split(separator: "-")
            guard parts.count == 5, parts[0] == "diagnostic", parts[1] == "ios",
                  let kind = DiagnosticKind(rawValue: String(parts[2])),
                  let time = TimeInterval(String(parts[3])), time.isFinite else { continue }
            let end = Date(timeIntervalSince1970: time)
            if end < cutoff {
                try? files.removeItem(at: file)
            } else {
                records.append(DiagnosticRecord(id: id, kind: kind, windowEnd: end, file: file))
            }
        }
        return records.sorted { $0.windowEnd == $1.windowEnd ? $0.id < $1.id : $0.windowEnd > $1.windowEnd }
    }

    private func readUploaded(at file: URL) -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Set<String>].self, from: data)) ?? [:]
    }

    private func writeUploaded(_ uploaded: [String: Set<String>], to file: URL) throws {
        try JSONEncoder().encode(uploaded).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@available(iOS 14.0, *)
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsCollector()
    private let queue = DispatchQueue(label: "com.screenrelay.diagnostics.collect", qos: .utility)

    func start() {
        MXMetricManager.shared.add(self)
        DiagnosticsStore.shared.snapshot(for: nil) { _ in }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            var drafts: [DiagnosticDraft] = []
            for payload in payloads where payload.timeStampEnd >= cutoff {
                for (index, crash) in (payload.crashDiagnostics ?? []).enumerated() {
                    var details: [String] = []
                    if let signal = crash.signal { details.append("Signal: \(signal)") }
                    if let type = crash.exceptionType { details.append("Exception type: \(type)") }
                    if let code = crash.exceptionCode { details.append("Exception code: \(code)") }
                    drafts.append(Self.draft(kind: .crash, index: index, payload: payload,
                                             version: crash.applicationVersion, details: details, stack: crash.callStackTree))
                }
                for (index, hang) in (payload.hangDiagnostics ?? []).enumerated() {
                    let seconds = hang.hangDuration.converted(to: .seconds).value
                    drafts.append(Self.draft(kind: .hang, index: index, payload: payload, version: hang.applicationVersion,
                                             details: ["Main thread blocked (seconds): \(seconds)"], stack: hang.callStackTree))
                }
            }
            if !drafts.isEmpty { DiagnosticsStore.shared.save(drafts) }
        }
    }

    private static func draft(
        kind: DiagnosticKind, index: Int, payload: MXDiagnosticPayload,
        version: String, details: [String], stack: MXCallStackTree
    ) -> DiagnosticDraft {
        let iso = ISO8601DateFormatter()
        let version = version.unicodeScalars
            .filter { (48...57).contains($0.value) || $0.value == 46 }
            .prefix(32)
            .map { String($0) }
            .joined()
        var lines = [
            "ScreenRelay iOS diagnostic",
            "Type: \(kind.rawValue)",
            "App version: \(version)",
            "MetricKit window begins: \(iso.string(from: payload.timeStampBegin))",
            "MetricKit window ends: \(iso.string(from: payload.timeStampEnd))",
            "The reporting window is not the time of the individual event.",
        ] + details
        lines += stackLines(stack.jsonRepresentation())
        let content = Data((lines.joined(separator: "\n") + "\n").utf8)
        let fingerprint = DiagnosticsStore.digest(Data("\(index)\n".utf8) + content)
        let id = "diagnostic-ios-\(kind.rawValue)-\(Int(payload.timeStampEnd.timeIntervalSince1970))-\(fingerprint)"
        return DiagnosticDraft(id: id, content: content)
    }

    private static func stackLines(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tree = root["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else {
            return []
        }
        var lines = ["Call stack frames (binary UUID, address, text offset):"]
        var remaining = 1024
        func appendFrames(_ frames: [[String: Any]], depth: Int) {
            guard depth < 64 else { return }
            for frame in frames {
                guard remaining > 0 else { return }
                remaining -= 1
                let uuid = (frame["binaryUUID"] as? String).flatMap { UUID(uuidString: $0) }?.uuidString ?? "?"
                let address = (frame["address"] as? NSNumber)?.uint64Value ?? 0
                let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
                lines.append("\(depth) \(uuid) 0x\(String(address, radix: 16)) 0x\(String(offset, radix: 16))")
                if let children = frame["subFrames"] as? [[String: Any]] {
                    appendFrames(children, depth: depth + 1)
                }
            }
        }
        for (index, stack) in stacks.prefix(64).enumerated() {
            guard remaining > 0 else { break }
            guard let frames = stack["callStackRootFrames"] as? [[String: Any]] else { continue }
            let attributed = (stack["threadAttributed"] as? Bool) == true ? " (attributed)" : ""
            lines.append("Stack \(index + 1)\(attributed):")
            appendFrames(frames, depth: 0)
        }
        return lines
    }
}
