# 截屏快传 iOS 端

最低部署目标为 iOS 13。工程使用 SwiftUI、系统相册选择器和系统网络接口，无第三方依赖。首页提供选图上传、扫码接收文件、电脑配对和诊断日志。

## 构建与安装

1. 在 Mac 上用 Xcode 打开 `ScreenRelay.xcodeproj`。若要从 Xcode 直接安装或调试 iOS 13 真机，请选用支持该系统版本的 Xcode。 [Apple 工具链和系统要求](https://developer.apple.com/xcode/system-requirements/)
2. 在 **ScreenRelay → Signing & Capabilities** 选择签名团队。如果 Xcode 提示标识符不可用，将 `com.screenrelay.sender` 改成团队可用的 Bundle Identifier。
3. 连接并选择 iPhone，点击 **Run**。按 iPhone 提示允许开发者模式或信任签名。
4. 在电脑启动接收端。让 iPhone 和电脑连入同一局域网，进入手机上的 **配对电脑**，点 **扫描电脑配对二维码**。也可手动填写电脑地址和配对码后点 **保存配对**。按系统提示允许相机或局域网访问。
5. 回到首页，点 **选择图片上传** 发送你选中的图片，或点 **扫码接收文件** 接收电脑分享的文件。

可在 Mac 上做无签名模拟器编译。

```sh
xcodebuild -project ScreenRelay.xcodeproj -scheme ScreenRelay \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 手动上传图片

手机和电脑接收端均更新至 0.7.0 或以上后，在手机首页点 **选择图片上传**，选择要发到已配对电脑的图片。iOS 14 及以上支持多选。系统选择器只向应用提供你选中的图片。

应用直接上传选择器提供的图片文件，并尽可能保留文件名和格式。iOS 13 的系统选择器支持单选。如果它只返回图像对象，应用会转为 JPEG。上传失败的文件会作为私有副本保留，重开应用也可点 **重试待传图片**。清除待传副本时，相册里的原图会保留。

## 从电脑接收文件

1. 在同一局域网内，从电脑端选择要分享的文件并生成文件分享二维码。
2. 在 iPhone 的截屏快传里点 **扫码接收文件**，扫描该二维码。第一次接收时允许相机和局域网访问。
3. 接收完成后可以在「文件」App 的「我的 iPhone／截屏快传」打开文件。遇到同名文件时，接收的文件名会附加编号。

接收中断后，可在分享有效期间点 **重试接收**，也可重新扫描原二维码。系统仍保留临时数据时，会从已接收的位置继续。

## 诊断日志

在首页打开 **诊断日志**，选中一条或多条报告，再点击 **上传所选日志**。报告以 TXT 上传到已配对的电脑。收到部分上传确认时，待重试的报告保持选中。

iOS 14 及以上通过 MetricKit 接收截屏快传自身的崩溃与卡顿诊断。报告可能延后或按窗口批量送达。列表时间取自系统报告窗口的结束时间，保留最近 24 小时内结束的窗口。每条日志在应用私有目录中保存，只整理崩溃或卡顿的结构化信息和堆栈地址。iOS 13 的诊断页面会显示系统版本要求。 [Apple MetricKit](https://developer.apple.com/documentation/metrickit)

## 局域网连接

iOS 17 及以上对直接使用 IP 地址的 HTTP 连接采用局域网例外，覆盖常用的私有、链路本地及共享地址段。若电脑显示的是其他网络地址，请使用受信任的 HTTPS。 [Apple ATS 例外域](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)
