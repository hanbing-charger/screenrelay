# 截屏快传 Android 客户端

支持 Android 10 及以上。手机保存系统截图或结束录屏后，应用从系统相册识别新文件，并把原文件发送到同一局域网内的 macOS 或 Windows 接收端。

## 安装和配对

1. 在电脑启动截屏快传接收端，在控制台找到手机端地址和配对码。
2. 在手机上打开发布包里的 Android APK，按系统提示允许当前来源安装应用。也可以用 USB 调试从电脑安装。
3. 让手机和电脑连接同一个可信 Wi-Fi。在手机应用中填写地址和配对码，点击「开始自动上传」。
4. 允许访问照片和视频。Android 14 以上请选择「允许所有照片和视频」，这样才能持续发现新文件。Android 13 以上也可以允许通知，方便查看运行状态和暂停上传。
5. 截一张图或录一段视频。桌面控制台会显示收到的文件。

USB 调试安装命令如下。

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

「测试连接」检查电脑地址和接收端响应，上传时会验证配对码。

## 后台同步

- 开始上传后，前台服务监听 Android 系统相册的变化。Android 15 会限制数据同步前台服务的运行时间，之后由系统调度任务继续同步，上传可能延迟。打开手机应用可以恢复实时监测。
- 相册匹配依据文件名和系统相册目录，可识别常见 Android 厂商的截屏、录屏命名。采用其他命名的机型可能需要适配。
- 电脑离线时，任务保存在手机上，并在后续同步时重试。保留原文件至上传完成。
- 应用内的「暂停自动上传」会停止传输。恢复后会补传暂停期间生成的截屏和录屏。

## 从源码构建

使用 JDK 17 和 Android SDK Platform 35。可以在 Android Studio 中打开本目录并构建，也可以运行项目附带的 Gradle Wrapper。

macOS 或 Linux

```sh
./gradlew assembleDebug
```

Windows PowerShell

```powershell
.\gradlew.bat assembleDebug
```

生成的调试 APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。从终端构建时，使用 `ANDROID_HOME` 或项目的 `local.properties` 指向已安装的 Android SDK。
