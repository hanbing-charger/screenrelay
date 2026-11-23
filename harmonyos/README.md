# 截屏快传 · 鸿蒙 NEXT

原生 HarmonyOS Stage 应用，适用于支持 HarmonyOS SDK API 12 及以上版本的手机和平板。可运行 Android APK 的旧版鸿蒙设备可以使用项目的 Android 发送端。

## 安装与配对

1. 用 DevEco Studio 打开本目录，安装 HarmonyOS SDK API 12 或更新版本。打开 **Project Structure → Signing Configs**，为已连接的设备配置调试签名，再运行 `entry`。
2. 启动电脑接收端，将手机连接到同一局域网。点击 **扫描配对二维码**，扫描电脑端显示的二维码，手机会保存接收地址和设备令牌。也可输入电脑端显示的地址与配对令牌，点击 **保存配对**。**测试连接** 检查电脑是否可达，实际发送时验证令牌。
3. 点击 **选择图片上传** 或 **选择录屏**，在系统相册里选择文件，返回应用后点击 **发送所选的文件**。手动选择支持普通照片、截图等图片，电脑端会将其列为「图片」。待传文件保存在手机的应用私有目录，发送成功后清理临时副本。网络中断时，应用打开期间会自动重试。

应用直接从手机连接配对地址，配对、测试和上传不经过系统 HTTP 代理。使用 HTTP 时，传输内容和令牌会以明文经过局域网。局域网内的 HTTPS 地址可在电脑接收端具备受手机信任的 HTTPS 入口时使用。

## 从电脑接收文件

在电脑端选择文件并生成文件二维码，在手机上点击 **扫码接收文件**。扫码后会自动把完整文件保存到应用私有的 `filesDir/received`。文件清单会显示保存路径，点击对应文件的 **导出**，可通过系统文件选择器将它复制到公共下载目录或其他位置。

网络短暂中断时，应用会在本次接收中尝试断点续传。电脑上的文件发生变化或分享过期时，请在电脑上重新生成文件二维码。未完成的文件留在应用私有临时目录，并在接收失败或重新启动应用后清理。

## 诊断日志

在手机首页打开 **诊断日志**，可查看系统已送达的近 24 小时本应用崩溃和无响应事件。勾选一份或多份报告后，点击 **发送所选日志**，将独立的 TXT 发送到已配对的电脑。发送失败的报告会保留，可再次发送。

应用使用鸿蒙 HiAppEvent 的 `APP_CRASH` 和 `APP_FREEZE`。系统可能在应用重新启动后才交付事件，功能首次启用前的历史事件无法补查。报告包含事件时间、应用版本和可用的筛选后调用栈，存储在应用私有目录，无需读取系统全局日志的权限。

## GitHub Actions 调试签名

在 DevEco Studio 或华为开发者平台准备同一套调试签名材料。先注册真机的 UDID，再用本地密钥库生成 CSR 并申请调试证书。创建调试 Profile 时，选择同一个证书和要安装的设备，应用的包名为 `com.screenrelay.sender`。保留创建密钥库时设置的密码与别名。

[注册设备](https://developer.huawei.com/consumer/cn/doc/App/agc-help-add-device-0000002283189937/) · [申请调试证书](https://developer.huawei.com/consumer/cn/doc/app/agc-help-add-debugcert-0000001914263178/) · [申请调试 Profile](https://developer.huawei.com/consumer/cn/doc/App/agc-help-debug-profile-0000002248181278/)

在仓库的 **Settings → Secrets and variables → Actions** 添加以下 Repository secrets。

| Secret | 值 |
| --- | --- |
| `HARMONY_KEYSTORE_BASE64` | `.p12` 的 Base64 内容 |
| `HARMONY_CERTIFICATE_BASE64` | 调试证书 `.cer` 的 Base64 内容 |
| `HARMONY_PROFILE_BASE64` | 调试描述文件 `.p7b` 的 Base64 内容 |
| `HARMONY_KEY_ALIAS` | 密钥别名 |
| `HARMONY_KEYSTORE_PASSWORD` | 密钥库密码 |
| `HARMONY_KEY_PASSWORD` | 私钥密码。与密钥库密码相同时可留空 |
| `HARMONY_ARTIFACT_PASSWORD` | 公开仓库的下载包密码。请使用单独生成的随机密码 |

在本机把每个签名文件编码为 Base64，再粘贴到相应 Secret。macOS 可用 `base64 < signing.p12 | tr -d '\r\n' | pbcopy` 复制到剪贴板。Windows PowerShell 可用 `Set-Clipboard -Value ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path '.\signing.p12').Path)))`。将命令里的文件名换成实际文件名。

打开 **Actions → Build HarmonyOS HAP → Run workflow**，选择 `main` 并勾选 `sign_hap`。构建通过后，在 **Artifacts** 下载 `screenrelay-harmonyos-signed`。公开仓库的产物内含一个加密的 `.7z`，用 `HARMONY_ARTIFACT_PASSWORD` 解压后取得签名 HAP。这样调试 Profile 中的设备标识受到保护。私有仓库的产物可直接解压得到 HAP。关闭 `sign_hap` 时仍可构建未签名版本。

## 获批安装包的自动上传

普通签名包默认可通过系统相册手动选取文件。华为将图库全量读取权限 `ohos.permission.READ_IMAGEVIDEO` 列为受限权限，设备间图片和视频同步属于可申请的用途。配置了包含该权限的华为签名 Profile 后，在 `entry/src/main/module.json5` 的 `requestPermissions` 数组中加入：

```json
{
  "name": "ohos.permission.READ_IMAGEVIDEO",
  "reason": "$string:read_media_reason",
  "usedScene": {
    "abilities": ["EntryAbility"],
    "when": "inuse"
  }
}
```

配对只保存接收地址和令牌。自动上传默认关闭，可在设置里打开 **自动上传截图和录屏**，并按系统提示授权相册访问。升级前已开启的设置会保留。权限未获授权时开关保持关闭，仍可手动选择上传。

应用根据媒体类型和系统命名识别新截图和录屏，例如 `Screenshot_20261120…` 或 `Screenrecorder_20261120…`。应用打开期间检查相册，返回时补查自启用以来的新文件。关闭开关后暂停待自动上传的文件，手动上传仍可使用。不同系统版本的文件名规则可能不同，未识别的文件可手动选取。

[华为受限权限说明](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/restricted-permissions/#section840962505912) · [系统相册选取指南](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/photoaccesshelper-photoviewpicker/)

## 真机验证

1. 在电脑启动接收端，使用鸿蒙手机扫码配对。随后测试连接、上传一张截图和一段录屏，确认电脑显示原始文件名和正确类型。
2. 停止接收端，再把两项文件加入队列。重新打开应用并启动接收端，确认队列可以重试。重复选取已发送文件，确认电脑上只有一份。
3. 用具备图库权限的安装包打开 **自动上传截图和录屏**。在应用前台截图，再切到其他应用录屏后返回，确认两类文件均进入队列。用原图和普通相机视频检查自动识别范围。
4. 将配对令牌改错，验证应用提示重新配对且保留待传队列。恢复正确令牌后确认待传项继续发送。
