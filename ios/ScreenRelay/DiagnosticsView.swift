import Combine
import Foundation
import SwiftUI

enum DiagnosticUploadIssue: LocalizedError {
    case settingsChanged
    case authorization

    var errorDescription: String? {
        switch self {
        case .settingsChanged:
            return "电脑配置已更改，请重新选择日志后上传。"
        case .authorization:
            return "电脑拒绝了配对凭据。请重新配对后重试。"
        }
    }
}

@MainActor
struct DiagnosticsView: View {
    @ObservedObject var model: SyncModel
    @State private var records: [DiagnosticRecord] = []
    @State private var uploaded: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var message: String?
    @State private var loading = true
    @State private var uploading = false

    var body: some View {
        Group {
            if #available(iOS 14.0, *) {
                diagnosticList
            } else {
                Text("本机系统为 iOS 13。崩溃和卡顿诊断需要 iOS 14 或以上版本。")
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .navigationBarTitle("诊断日志", displayMode: .inline)
    }

    private var diagnosticList: some View {
        List {
            Section(
                header: Text("最近 24 小时的报告窗口"),
                footer: Text("iOS 提供截屏快传自己的崩溃和卡顿报告，可能延后送达。所示时间是系统报告窗口结束时间。")
            ) {
                if loading {
                    HStack {
                        ActivityIndicator().frame(width: 24, height: 24)
                        Text("正在读取本机日志…")
                    }
                } else if records.isEmpty {
                    Text("暂无系统报告").foregroundColor(.secondary)
                }
                ForEach(records) { record in
                    Button {
                        if selected.contains(record.id) {
                            selected.remove(record.id)
                        } else {
                            selected.insert(record.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                .accessibility(hidden: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.kind.title).foregroundColor(.primary)
                                Text(DateFormatter.localizedString(from: record.windowEnd, dateStyle: .short, timeStyle: .short))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if uploaded.contains(record.id) {
                                Text("已上传").font(.footnote).foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibility(value: Text(selected.contains(record.id) ? "已选中" : "未选中"))
                    .disabled(uploading)
                }
            }

            Section(footer: Text("日志存放在应用私有目录。选中日志后，点上传才会发送到已配对的电脑。")) {
                Button(uploading ? "正在上传…" : "上传所选日志（\(selected.count)）", action: uploadSelected)
                    .disabled(uploading || selected.isEmpty || model.settings == nil)
                if model.settings == nil {
                    Text("请先在首页配对电脑。").foregroundColor(.secondary)
                }
                if let message {
                    Text(message).foregroundColor(.secondary)
                }
            }
        }
        .listStyle(GroupedListStyle())
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: DiagnosticsStore.changed)) { _ in refresh() }
    }

    private func refresh() {
        let receiver = model.settings?.baseURL
        DiagnosticsStore.shared.snapshot(for: receiver) { result in
            loading = false
            switch result {
            case .success(let snapshot):
                records = snapshot.records
                selected.formIntersection(Set(records.map(\.id)))
                if model.settings?.baseURL == receiver {
                    uploaded = snapshot.uploaded
                }
            case .failure:
                message = "无法读取本机诊断日志。"
            }
        }
    }

    private func uploadSelected() {
        guard !uploading, let settings = model.settings else { return }
        let pending = records.filter { selected.contains($0.id) }
        guard !pending.isEmpty else { return }
        uploading = true
        message = nil

        Task {
            var succeeded = 0
            var failure: String?
            for record in pending {
                do {
                    let status = try await model.sendDiagnostic(record, to: settings)
                    switch status {
                    case 200, 201:
                        DiagnosticsStore.shared.markUploaded(record.id, to: settings.baseURL)
                        uploaded.insert(record.id)
                        selected.remove(record.id)
                        succeeded += 1
                    case 401, 403:
                        throw DiagnosticUploadIssue.authorization
                    default:
                        failure = failure ?? ReceiverIssue.response(status).localizedDescription
                    }
                } catch {
                    failure = failure ?? error.localizedDescription
                    break
                }
            }
            uploading = false
            if succeeded == pending.count {
                message = "已上传 \(succeeded) 条诊断日志。"
            } else {
                let remaining = pending.count - succeeded
                message = "已上传 \(succeeded) 条，仍有 \(remaining) 条待传。\(failure ?? "可重试所选日志。")"
            }
            refresh()
        }
    }
}
