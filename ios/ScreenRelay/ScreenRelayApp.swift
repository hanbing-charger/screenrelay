import BackgroundTasks
import Combine
import Photos
import SwiftUI
import UIKit

@MainActor
final class ScreenRelayDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SyncModel.processingID, using: .main) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await SyncModel.shared.runBackground(processing)
            }
        }
        return true
    }
}

@main
@MainActor
struct ScreenRelayApp: App {
    @UIApplicationDelegateAdaptor(ScreenRelayDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = SyncModel.shared

    var body: some Scene {
        WindowGroup {
            PairingView(model: model)
                .task { if phase == .active { model.becameActive() } }
                .onChange(of: phase) { phase in
                    switch phase {
                    case .active:
                        model.becameActive()
                    case .background:
                        model.enteredBackground()
                    default:
                        break
                    }
                }
        }
    }
}

@MainActor
private struct PairingView: View {
    @ObservedObject var model: SyncModel
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @State private var token = ""
    @State private var testResult: String?
    @State private var testing = false
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8765", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("电脑端地址")
                    SecureField("配对码", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button("保存配置") { model.saveSettings(address: address, token: token) }
                            .buttonStyle(.borderedProminent)
                        Button("测试连接") {
                            testing = true
                            testResult = nil
                            let testedAddress = address
                            let testedToken = token
                            Task {
                                let result = await model.testSettings(address: testedAddress, token: testedToken)
                                if address == testedAddress && token == testedToken { testResult = result }
                                testing = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(testing)
                        if testing {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if let testResult {
                        Text(testResult).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("配对电脑")
                } footer: {
                    Text("让 iPhone 和电脑连接到同一局域网，再填写接收端显示的地址和配对码。")
                }

                Section {
                    Toggle("自动上传", isOn: Binding(
                        get: { model.enabled },
                        set: { model.setEnabled($0) }
                    ))
                    .disabled(model.settings == nil)

                    switch model.permission {
                    case .authorized:
                        Label("已获相册访问权限", systemImage: "photo.on.rectangle")
                            .foregroundStyle(.secondary)
                    case .limited:
                        Button("在设置中允许访问所有照片", action: openSettings)
                    case .notDetermined:
                        Button("允许读取相册") { Task { await model.requestPermission() } }
                    default:
                        Button("在设置中开启相册访问", action: openSettings)
                    }

                    Button("立即扫描并上传", action: model.syncNow)
                        .disabled(!model.enabled || model.running)
                } header: {
                    Text("自动同步")
                } footer: {
                    Text("首次开启后，自动同步此后保存到相册的截屏和录屏。iOS 后台扫描由系统调度。需要立即同步时，请打开本应用。")
                }

                Section("进度") {
                    LabeledContent("已上传", value: "\(model.uploadedCount)")
                    LabeledContent("本次待传", value: "\(model.pending)")
                    HStack(alignment: .top) {
                        if model.running { ProgressView().controlSize(.small) }
                        Text(model.lastStatus).foregroundStyle(.secondary)
                    }
                }

                if !model.failureMessages.isEmpty {
                    Section("失败记录") {
                        ForEach(Array(model.failureMessages.enumerated()), id: \.offset) { entry in
                            Text(entry.element)
                        }
                        Button("重试失败文件", action: model.retryFailures)
                            .disabled(!model.enabled || model.running)
                    }
                }
            }
            .navigationTitle("截屏快传")
            .onAppear {
                guard let settings = model.settings else { return }
                address = settings.baseURL.absoluteString
                token = settings.token
            }
            .onChange(of: address) { _ in testResult = nil }
            .onChange(of: token) { _ in testResult = nil }
            .onReceive(timer) { _ in model.foregroundTick() }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
