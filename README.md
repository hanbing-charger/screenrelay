# 截屏快传

把手机新保存的截图和录屏传到 Mac 或 Windows。手机通过同一局域网直连电脑，电脑接收原始文件，并按接收日期和媒体类型保存。接收器关闭或断网时，手机可以在系统允许的下一次同步时补传。

## 电脑端

1. 解压与电脑对应的接收器包。Apple 芯片 Mac 选 macOS-arm64，Intel Mac 选 macOS-x64。常见 Windows 电脑选 Windows-x64，ARM 版 Windows 选 Windows-arm64。
2. Mac 双击「启动截屏快传.command」，Windows 双击「ScreenRelay.exe」。如果防火墙询问，允许在私人网络接收。构建未做商业签名或 Apple 公证，首次启动时系统可能要求在安全设置里确认来源。
3. 浏览器会打开电脑控制台。复制其中的**电脑地址**和**配对码**到手机。若显示多个地址，选手机所在 Wi-Fi 对应的网卡地址。
4. 保持接收器窗口运行。收到的文件会出现在控制台，默认保存于用户目录下的 `ScreenRelay` 文件夹，按日期及 `screenshot`、`screen-recording` 分类。按 `Ctrl+C` 或关闭接收器窗口可停止接收。

## 手机端

在手机端填入地址和配对码，授予所需权限后开启同步，再截一张图或录一段视频。截图和录屏需要先保存到系统相册。自动同步从首次开启时开始收集。鸿蒙应用可手动选择相册中的文件。

| 手机系统 | 使用方式 |
| --- | --- |
| Android 10 及以上 | 安装 APK，填写配对信息，授予完整照片和视频权限并启动同步。同步服务运行时可在后台监听，系统调度也会尝试补传。系统省电策略、强行停止和部分厂商的保存目录可能影响发现时间。 |
| iOS 16 及以上 | 用 Xcode 打开 iOS 工程并签名安装。允许访问局域网和完整相册。App 打开时检测并上传，系统调度的后台任务也可补传。iOS 无法保证应用挂起或被强行退出后立即检测每次系统截图和录屏。 |
| HarmonyOS NEXT | 用 DevEco Studio 构建 ArkTS 工程。自动扫描依赖华为的完整图片和视频读取权限审批与用户授权。获得权限后可在应用运行期间自动发现并补传。默认构建可手动从系统相册选择文件。支持 Android APK 的早期鸿蒙机型可使用 Android 端。 |

各平台的构建和权限细节见源码中的 [Android](android)、[iOS](ios) 和 [HarmonyOS](harmonyos) 目录。

## 连接与保存

- 手机和电脑需要能在局域网内互相访问。访客 Wi-Fi 可能隔离设备，电脑地址变动后需更新手机配置。
- 默认接收端口是 TCP 8765，传输为局域网 HTTP。请在可信 Wi-Fi 中使用。若启用 HTTPS，手机需信任证书，填写的主机名或 IP 需与证书匹配。控制台独立监听在电脑本机。
- 默认最大单文件为 2 GiB。电脑端可用下面的参数指定保存目录、端口和限制，一次只运行一个接收器实例。

```text
ScreenRelay -folder "/path/to/captures" -listen 0.0.0.0:8765 -max-mib 4096
ScreenRelay -tls-cert fullchain.pem -tls-key privkey.pem
```

## 从源码构建

电脑端使用 Go 1.24 及以上版本，标准库之外无需安装依赖。在 `desktop` 目录运行：

```sh
go test ./...
go build -o ScreenRelay .
```

Windows 使用 `go build -o ScreenRelay.exe .`。手机工程需用各平台工具链编译并签名。接收接口约定见 [desktop/PROTOCOL.md](desktop/PROTOCOL.md)。
