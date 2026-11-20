import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
struct PairQRCodeSheet: View {
    let instruction: String
    let unavailableMessage: String
    let onRead: (String) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var cameraUnavailable = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                switch permission {
                case .authorized where !cameraUnavailable:
                    QRScannerPreview(onRead: onRead, onFailure: { cameraUnavailable = true })
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibility(label: Text("二维码相机取景器"))
                    Text(instruction)
                        .foregroundColor(.secondary)
                case .denied:
                    Text("扫描二维码需要相机权限。")
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                case .notDetermined:
                    HStack {
                        ActivityIndicator().frame(width: 24, height: 24)
                        Text("正在等待相机授权…")
                    }
                default:
                    Text(unavailableMessage)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationBarTitle("扫描二维码", displayMode: .inline)
            .navigationBarItems(leading:
                Button("取消") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            if permission == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { refreshPermission() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            refreshPermission()
        }
    }

    private func refreshPermission() {
        permission = AVCaptureDevice.authorizationStatus(for: .video)
    }
}

private struct QRScannerPreview: UIViewControllerRepresentable {
    let onRead: (String) -> Void
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onRead: onRead, onFailure: onFailure)
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

private final class QRMetadataReader: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let onRead: (String) -> Void
    private var delivered = false

    init(onRead: @escaping (String) -> Void) {
        self.onRead = onRead
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let result = objects.lazy.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else {
            return
        }
        delivered = true
        onRead(result)
    }
}

private final class QRCamera {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.screenrelay.qr-camera")
    private var configured = false

    func start(reader: QRMetadataReader, onFailure: @escaping () -> Void) {
        queue.async {
            if !self.configured {
                self.configured = self.configure(reader: reader)
            }
            if self.configured && !self.session.isRunning {
                self.session.startRunning()
            }
            if !self.session.isRunning {
                DispatchQueue.main.async { onFailure() }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure(reader: QRMetadataReader) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            return false
        }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.removeInput(input)
            return false
        }
        output.setMetadataObjectsDelegate(reader, queue: .main)
        output.metadataObjectTypes = [.qr]
        return true
    }
}

private final class QRScannerController: UIViewController {
    private let camera = QRCamera()
    private let reader: QRMetadataReader
    private let onFailure: () -> Void
    private var preview: AVCaptureVideoPreviewLayer?

    init(onRead: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        reader = QRMetadataReader(onRead: onRead)
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: camera.session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        camera.start(reader: reader, onFailure: onFailure)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        camera.stop()
    }
}
