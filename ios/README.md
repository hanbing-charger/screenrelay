# 截屏快传 iOS 端

最低部署目标为 iOS 13。工程使用 SwiftUI、PhotoKit 和系统网络接口，无第三方依赖。首次开启自动上传后，按相册素材的创建时间收集此后保存的截屏和录屏。普通相机照片及视频不会进入队列。启用 iCloud 照片时，同步会依据当前可见的相册素材。

## 构建与安装

1. 在 Mac 上用 Xcode 打开 `ScreenRelay.xcodeproj`。若要从 Xcode 直接安装或调试 iOS 13 真机，请选用支持该系统版本的 Xcode。 [Apple 工具链和系统要求](https://developer.apple.com/xcode/system-requirements/)
2. 在 **ScreenRelay → Signing & Capabilities** 选择签名团队。如果 Xcode 提示标识符不可用，将 `com.screenrelay.sender` 改成团队可用的 Bundle Identifier。工程会从标识符生成后台任务 ID。
3. 连接并选择 iPhone，点击 **Run**。按 iPhone 提示允许开发者模式或信任签名。
4. 在电脑启动接收端。让 iPhone 和电脑连入同一局域网，点击手机上的 **扫描电脑配对二维码**，允许使用相机，再扫描电脑端显示的二维码。配对成功后会自动保存配置。也可手动填写电脑地址和配对码后保存。
5. 允许局域网和完整相册访问，开启自动上传，再使用系统截屏或控制中心录屏并保存到相册。打开应用时会自动检查，亦可用 **立即扫描并上传** 触发。电脑端离线时，再连通并重新检查即可重试。

可在 Mac 上做无签名模拟器编译。

```sh
xcodebuild -project ScreenRelay.xcodeproj -scheme ScreenRelay \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 从电脑接收文件

1. 在同一局域网内，从电脑端选择要分享的文件并生成文件分享二维码。
2. 在 iPhone 的截屏快传里点 **扫码接收文件**，扫描该二维码。第一次接收时允许相机和局域网访问。
3. 接收完成后可以在「文件」App 的「我的 iPhone／截屏快传」打开文件。遇到同名文件时，接收的文件名会附加编号。

接收中断后，可在分享有效期间点 **重试接收**，也可重新扫描原二维码。系统仍保留临时数据时，会从已接收的位置继续。

## iOS 同步行为

- 应用运行时使用 PhotoKit 变更通知自动检查，新素材也会在打开应用时补查。iOS 13 通过 PhotoKit 的录屏类型识别录屏，iOS 14 及以上也会检查录屏智能相簿。
- 切换到其他应用后，系统提供一小段收尾时间。应用还会申请系统调度的后台扫描，系统调度时间取决于网络、用电和使用状况。应用被挂起或者从多任务界面划掉时，重新打开可补传。
- iOS 17 及以上对直接使用 IP 地址的 HTTP 连接采用局域网例外，覆盖常用的私有、链路本地及共享地址段。若电脑显示的是其他网络地址，请使用受信任的 HTTPS。 [Apple ATS 例外域](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)
- 局域网传输拒绝 HTTP 重定向，避免文件或配对码被转发。上传在应用可执行期间运行，系统中止后，下次检查会使用相同上传 ID 重试。成功记录保存在本机，源素材须在上传成功前留在相册。
- iOS 14 及以上可限制应用只访问部分照片，此时应用只能看见用户选中的素材。要自动发现后续新增的截屏和录屏，请允许完整相册访问。iOS 13 会提示是否允许访问相册。
- 暂停会停止扫描与当前上传。重新开启时会检查首次开启以来尚未上传的素材。更换电脑配置后，已完成的素材保留完成状态，待传文件会发往新配置的接收端。

[Apple PhotoKit 录屏智能相簿](https://developer.apple.com/documentation/photos/phassetcollectionsubtype/smartalbumscreenrecordings) · [Apple 后台任务](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app) · [Apple 后台会话的重定向规则](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
