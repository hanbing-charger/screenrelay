import SwiftUI
import UIKit

@main
@MainActor
final class ScreenRelayDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if #available(iOS 14.0, *) {
            DiagnosticsCollector.shared.start()
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
    private let downloads = FileReceiveModel()
    private let imageUploads = ImageUploadModel()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: HomeView(
            model: SyncModel.shared, downloads: downloads, imageUploads: imageUploads
        ))
        self.window = window
        window.makeKeyAndVisible()
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

private struct FileReceiveProgress: UIViewRepresentable {
    let value: Float

    func makeUIView(context: Context) -> UIProgressView {
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progressTintColor = HomePalette.actionColor
        return progress
    }

    func updateUIView(_ view: UIProgressView, context: Context) {
        view.progress = value
    }
}

private enum HomePalette {
    static let actionColor = UIColor(red: 37.0 / 255, green: 88.0 / 255, blue: 221.0 / 255, alpha: 1)
    static let action = Color(actionColor)
    static let link = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.60, green: 0.72, blue: 1, alpha: 1) : actionColor
    })
    static let canvas = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)
            : UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1)
    })
    static let card = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.15, blue: 0.21, alpha: 1)
            : .white
    })
    static let border = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.22, green: 0.27, blue: 0.37, alpha: 1)
            : UIColor(red: 0.85, green: 0.89, blue: 0.95, alpha: 1)
    })
}

private struct HomeCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HomePalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(HomePalette.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

@MainActor
private struct HomeView: View {
    private enum Modal: String, Identifiable {
        case download
        case images

        var id: String { rawValue }
    }

    @ObservedObject var model: SyncModel
    @ObservedObject var downloads: FileReceiveModel
    @ObservedObject var imageUploads: ImageUploadModel
    @State private var modal: Modal?
    @State private var confirmDiscard = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    imageUpload
                    fileReceive
                    pairingLink
                    diagnosticsLink
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(HomePalette.canvas.edgesIgnoringSafeArea(.all))
            .navigationBarTitle("截屏快传", displayMode: .large)
            .sheet(item: $modal) { purpose in
                if purpose == .images {
                    PhotoPickerSheet { selection in
                        guard modal == .images else { return }
                        modal = nil
                        imageUploads.accept(selection, sync: model)
                    }
                } else {
                    PairQRCodeSheet(
                        instruction: "将相机对准电脑接收端的文件分享二维码。",
                        unavailableMessage: "相机当前不可用，请检查相机后重试。"
                    ) { value in
                        guard modal == .download else { return }
                        modal = nil
                        downloads.receive(scannedValue: value)
                    }
                }
            }
            .alert(isPresented: $confirmDiscard) {
                Alert(
                    title: Text("清除待传图片？"),
                    message: Text("仅删除应用保存的待传副本，相册原图会保留。"),
                    primaryButton: .destructive(Text("清除"), action: imageUploads.discardPending),
                    secondaryButton: .cancel()
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(HomePalette.link)
    }

    private var canChooseImages: Bool {
        model.settings != nil && !imageUploads.busy
    }

    private var imageUpload: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                modal = .images
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle").accessibility(hidden: true)
                    Text("选择图片上传").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.headline)
                .foregroundColor(model.settings == nil ? HomePalette.link : .white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(minHeight: 54)
                .background(model.settings == nil ? HomePalette.canvas : HomePalette.action)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canChooseImages)

            if model.settings == nil {
                Text("配对电脑后可上传图片。").font(.subheadline).foregroundColor(.secondary)
            }
            if let message = imageUploads.message {
                HStack(alignment: .top, spacing: 8) {
                    if imageUploads.busy {
                        ActivityIndicator().frame(width: 22, height: 22).accessibility(hidden: true)
                    }
                    Text(message).foregroundColor(.secondary)
                }
            }
            if !imageUploads.pending.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("待传图片 \(imageUploads.pending.count) 张")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("重试待传图片") { imageUploads.retry(sync: model) }
                        .frame(minHeight: 44, alignment: .leading)
                        .disabled(!canChooseImages)
                    Button("清除待传副本") { confirmDiscard = true }
                        .frame(minHeight: 44, alignment: .leading)
                        .disabled(imageUploads.busy)
                }
            }
        }
        .modifier(HomeCard())
    }

    private var fileReceive: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                modal = .download
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode").accessibility(hidden: true)
                    Text("扫码接收文件").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.headline)
                .foregroundColor(HomePalette.link)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(downloads.isReceiving)

            switch downloads.status {
            case .idle:
                EmptyView()
            case .preparing:
                HStack {
                    ActivityIndicator().frame(width: 22, height: 22).accessibility(hidden: true)
                    Text("正在读取文件信息…").foregroundColor(.secondary)
                }
            case .receiving(let name, let bytes, let total):
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在接收 \(name)")
                    if total > 0 {
                        FileReceiveProgress(value: Float(bytes) / Float(total)).frame(height: 4)
                        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .foregroundColor(.secondary)
                    }
                }
            case .finished(let name):
                Text("已接收 \(name)").foregroundColor(.secondary)
                Text("文件 → 我的 iPhone → 截屏快传").font(.subheadline).foregroundColor(.secondary)
            case .failed(let message):
                Text(message).foregroundColor(.secondary)
            }
            if downloads.canRetry {
                Button("重试接收", action: downloads.retry).frame(minHeight: 44, alignment: .leading)
            }
        }
        .modifier(HomeCard())
    }

    private var pairingLink: some View {
        NavigationLink(destination: PairingSettingsView(model: model)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.headline)
                    .foregroundColor(HomePalette.link)
                    .accessibility(hidden: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.settings == nil ? "配对电脑" : "已配对电脑")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(model.settings?.baseURL.absoluteString ?? "扫码或手动填写电脑地址")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibility(hidden: true)
            }
            .modifier(HomeCard())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var diagnosticsLink: some View {
        NavigationLink(destination: DiagnosticsView(model: model)) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundColor(HomePalette.link).accessibility(hidden: true)
                Text("诊断日志").foregroundColor(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibility(hidden: true)
            }
            .font(.headline)
            .modifier(HomeCard())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

@MainActor
private struct PairingSettingsView: View {
    @ObservedObject var model: SyncModel
    @State private var address = ""
    @State private var token = ""
    @State private var testResult: String?
    @State private var saveResult: String?
    @State private var pairingResult: String?
    @State private var testing = false
    @State private var pairing = false
    @State private var scanner = false

    var body: some View {
        Form {
            Section(
                header: Text("扫码配对"),
                footer: Text("将 iPhone 和电脑连接到同一局域网。")
            ) {
                Button {
                    pairingResult = nil
                    scanner = true
                } label: {
                    HStack {
                        Image(systemName: "qrcode").accessibility(hidden: true)
                        Text("扫描电脑配对二维码")
                    }
                }
                if pairing {
                    HStack {
                        ActivityIndicator().frame(width: 22, height: 22).accessibility(hidden: true)
                        Text("正在配对…").foregroundColor(.secondary)
                    }
                } else if let pairingResult {
                    Text(pairingResult).foregroundColor(.secondary)
                }
            }
            .disabled(pairing)

            Section(header: Text("手动配对")) {
                TextField("http://192.168.1.20:8765", text: Binding(
                    get: { address },
                    set: {
                        address = $0
                        testResult = nil
                        saveResult = nil
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
                        saveResult = nil
                    }
                ))
                .autocapitalization(.none)
                .disableAutocorrection(true)

                Button("保存配对") {
                    pairingResult = nil
                    model.saveSettings(address: address, token: token)
                    saveResult = model.pairingStatus
                }
                Button("测试连接", action: testConnection).disabled(testing)

                if let saveResult {
                    Text(saveResult).foregroundColor(.secondary)
                }
                if testing {
                    HStack {
                        ActivityIndicator().frame(width: 22, height: 22).accessibility(hidden: true)
                        Text("正在测试连接…").foregroundColor(.secondary)
                    }
                } else if let testResult {
                    Text(testResult).foregroundColor(.secondary)
                }
            }
            .disabled(pairing)
        }
        .navigationBarTitle("电脑配对", displayMode: .inline)
        .sheet(isPresented: $scanner) {
            PairQRCodeSheet(
                instruction: "将相机对准电脑接收端的配对二维码。",
                unavailableMessage: "相机当前不可用。可返回手动填写电脑地址和配对码。"
            ) { value in
                guard scanner else { return }
                scanner = false
                pairWithQRCode(value)
            }
        }
        .onAppear {
            guard let settings = model.settings else { return }
            address = settings.baseURL.absoluteString
            token = settings.token
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
        guard !pairing else { return }
        pairing = true
        Task {
            defer { pairing = false }
            do {
                let settings = try await model.pair(scannedValue: scannedValue)
                address = settings.baseURL.absoluteString
                token = settings.token
                testResult = nil
                saveResult = nil
                pairingResult = "配对成功。"
            } catch {
                pairingResult = "配对失败。\(error.localizedDescription)"
            }
        }
    }
}
