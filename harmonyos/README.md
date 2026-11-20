# 截屏快传 · 鸿蒙 NEXT

原生 HarmonyOS Stage 应用，适用于支持 HarmonyOS SDK API 12 及以上版本的手机和平板。可运行 Android APK 的旧版鸿蒙设备可以使用项目的 Android 发送端。

## 安装与配对

1. 用 DevEco Studio 打开本目录，安装 HarmonyOS SDK API 12 或更新版本。打开 **Project Structure → Signing Configs**，为已连接的设备配置调试签名，再运行 `entry`。
2. 启动电脑接收端，将手机连接到同一局域网。输入电脑端显示的地址与配对令牌，点击 **保存配对**。**测试连接** 检查电脑是否可达，实际发送时验证令牌。
3. 点击 **选择截图** 或 **选择录屏**，在系统相册里选择文件，返回应用后点击 **发送所选的文件**。待传文件保存在手机上的应用私有目录，发送成功后清理临时副本。网络中断时，应用打开期间会自动重试。

应用直接从手机发送到配对地址。使用 HTTP 时，传输内容和令牌会以明文经过局域网。局域网内的 HTTPS 地址可在电脑接收端具备受手机信任的 HTTPS 入口时使用。

## 获批安装包的自动发现

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

安装获批包后，配对电脑并点击 **授权并开启**。应用根据媒体类型和系统命名识别新截图和录屏，例如 `Screenshot_20261120…` 或 `Screenrecorder_20261120…`。应用打开期间检查相册，切回后补查自启用以来的新文件。文件名规则因设备版本而异，如果某个文件未被识别，可以通过系统相册选取。关闭应用或切换到后台后，系统可暂停应用，因此返回应用时补传。

[华为受限权限说明](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/restricted-permissions/#section840962505912) · [系统相册选取指南](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/photoaccesshelper-photoviewpicker/)

## 真机验证

1. 在电脑启动接收端，使用鸿蒙手机测试连接、上传一张截图和一段录屏，确认电脑显示原始文件名和正确类型。
2. 停止接收端，再把两项文件加入队列。重新打开应用并启动接收端，确认队列可以重试。重复选取已发送文件，确认电脑上只有一份。
3. 用具备图库权限的安装包开启自动发现。在应用前台截图，再切到其他应用录屏后返回，确认两类文件均进入队列。用原图和普通相机视频检查自动识别范围。
4. 将配对令牌改错，验证应用提示重新配对且保留待传队列。恢复正确令牌后确认待传项继续发送。
