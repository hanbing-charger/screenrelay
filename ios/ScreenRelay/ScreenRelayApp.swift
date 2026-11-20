import BackgroundTasks
import Combine
import SwiftUI
import UIKit

@main
@MainActor
final class ScreenRelayDelegate: UIResponder, UIApplicationDelegate {
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

    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = ScreenRelaySceneDelegate.self
        return configuration
    }
}

@MainActor
final class ScreenRelaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: PairingView(model: SyncModel.shared))
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        SyncModel.shared.becameActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        SyncModel.shared.enteredBackground()
    }
}

struct ActivityIndicator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        return indicator
    }

    func updateUIView(_ indicator: UIActivityIndicatorView, context: Context) {}
}

@MainActor
private struct PairingView: View {
    @ObservedObject var model: SyncModel
    @State private var address = ""
    @State private var token = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var showingScanner = false
    @State private var pairing = false
    @State private var pairingResult: String?
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Form {
                pairingSection
                syncSection
                progressSection
                if !model.failureMessages.isEmpty {
                    Section(header: Text("失败记录")) {
                        ForEach(Array(model.failureMessages.enumerated()), id: \.offset) { entry in
                            Text(entry.element)
                        }
                        Button("重试失败文件", action: model.retryFailures)
                            .disabled(!model.enabled || model.running)
                    }
                }
            }
            .navigationBarTitle("截屏快传")
            .sheet(isPresented: $showingScanner) {
                PairQRCodeSheet(onRead: pairWithQRCode)
            }
            .onAppear {
                guard let settings = model.settings else { return }
                address = settings.baseURL.absoluteString
                token = settings.token
            }
            .onReceive(timer) { _ in model.foregroundTick() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var pairingSection: some View {
        Section(
            header: Text("配对电脑"),
            footer: Text("让 iPhone 和电脑连接到同一局域网。扫描接收端的配对二维码，或手动填写电脑地址和配对码。")
        ) {
            Button {
                pairingResult = nil
                showingScanner = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                    Text("扫描电脑配对二维码")
                }
            }

            if pairing {
                HStack {
                    ActivityIndicator().frame(width: 24, height: 24)
                    Text("正在配对…")
                }
            } else if let pairingResult {
                Text(pairingResult).foregroundColor(.secondary)
            }

            TextField("http://192.168.1.20:8765", text: Binding(
                get: { address },
                set: {
                    address = $0
                    testResult = nil
                }
            ))
            .keyboardType(.URL)
            .textContentType(.URL)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .accessibility(label: Text("电脑端地址"))

            SecureField("配对码或设备令牌", text: Binding(
                get: { token },
                set: {
                    token = $0
                    testResult = nil
                }
            ))
            .autocapitalization(.none)
            .disableAutocorrection(true)

            Button("保存配置") {
                pairingResult = nil
                model.saveSettings(address: address, token: token)
            }
            Button("测试连接", action: testConnection).disabled(testing)
            if testing {
                HStack {
                    ActivityIndicator().frame(width: 24, height: 24)
                    Text("正在测试连接…").foregroundColor(.secondary)
                }
            } else if let testResult {
                Text(testResult).foregroundColor(.secondary)
            }
        }
        .disabled(pairing)
    }

    private var syncSection: some View {
        Section(
            header: Text("自动同步"),
            footer: Text("首次开启后，自动同步此后保存到相册的截屏和录屏。iOS 后台扫描由系统调度。需要立即同步时，请打开本应用。")
        ) {
            Toggle("自动上传", isOn: Binding(
                get: { model.enabled },
                set: { model.setEnabled($0) }
            ))
            .disabled(model.settings == nil)

            switch model.permission {
            case .authorized:
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("已获相册访问权限")
                }
                .foregroundColor(.secondary)
            case .limited:
                Button("在设置中允许访问所有照片", action: openSettings)
            case .notDetermined:
                Button("允许读取相册") { Task { await model.requestPermission() } }
            case .denied:
                Button("在设置中开启相册访问", action: openSettings)
            }

            Button("立即扫描并上传", action: model.syncNow)
                .disabled(!model.enabled || model.running)
        }
    }

    private var progressSection: some View {
        Section(header: Text("进度")) {
            HStack {
                Text("已上传")
                Spacer()
                Text("\(model.uploadedCount)").foregroundColor(.secondary)
            }
            HStack {
                Text("本次待传")
                Spacer()
                Text("\(model.pending)").foregroundColor(.secondary)
            }
            HStack(alignment: .top) {
                if model.running {
                    ActivityIndicator().frame(width: 24, height: 24)
                }
                Text(model.lastStatus).foregroundColor(.secondary)
            }
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        let testedAddress = address
        let testedToken = token
        Task {
            let result = await model.testSettings(address: testedAddress, token: testedToken)
            if address == testedAddress && token == testedToken {
                testResult = result
            }
            testing = false
        }
    }

    private func pairWithQRCode(_ scannedValue: String) {
        guard showingScanner, !pairing else { return }
        showingScanner = false
        pairing = true
        Task {
            defer { pairing = false }
            do {
                let settings = try await model.pair(scannedValue: scannedValue)
                address = settings.baseURL.absoluteString
                token = settings.token
                testResult = nil
                pairingResult = "配对成功，电脑配置已保存。"
            } catch {
                pairingResult = "配对失败。\(error.localizedDescription)"
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
