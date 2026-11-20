# 截屏快传接收接口

电脑上传服务默认监听 IPv4 TCP 8765。电脑控制台使用独立的本地端口，手机端应使用控制台显示的局域网地址。

- `GET /api/v1/health` 返回 `200` 和 `{"status":"ok","version":"0.5.0"}`，用于检查接收器地址是否可达。
- `POST /api/v1/uploads` 上传原始文件字节，需指定 `Content-Length`。文件名使用 RFC 3986 UTF-8 百分号编码后放入 `X-Filename`，类型放入 `X-Media-Kind`（`screenshot` 或 `screen-recording`），将扫码配对得到的令牌或手动配对码放入 `Authorization: Bearer <token>`。建议设置实际 `Content-Type`。
- `X-Upload-Id` 可提供设备内稳定、设备间唯一的重试标识，支持 1 至 128 个 ASCII 字符 `A–Z a–z 0–9 . _ -`。
- 返回 `201` 表示保存完成，`200` 表示同一个 ID 对应的同一文件已保存。响应为 JSON，含 `id` 和 `name`。
- `401` 表示配对码错误，`409` 表示同一个 ID 已用于其他文件，`411` 表示缺少长度，`413` 表示超过文件上限，`415` 表示扩展名与支持的类型不符。网络错误和 `5xx` 可用同一个上传 ID 重试。接收端在上传连续 90 秒无数据时返回可重试的 `503`，连续发送的文件仍可使用 45 分钟的总上传时限。

## 扫码配对

电脑控制台显示格式为 `screenrelay://pair?v=1&url=<RFC3986 编码的电脑地址>&code=<短期配对码>` 的二维码。二维码有效期为十分钟，期间可配对多台手机。

- 手机向 `POST /api/v1/pair` 发送 UTF-8 JSON，字段为 `pairingCode`、`deviceId` 和 `deviceName`。其中 `deviceId` 是安装后持久保存的标识符，允许的字符集与 `X-Upload-Id` 相同。
- 返回 `201` 表示新配对，`200` 表示此前已配对，两者都返回 JSON `{"token":"<设备令牌>"}`。手机保存电脑地址和设备令牌。重复发起同一设备的配对只有一条记录。
- `401` 表示二维码过期或配对码有误。已配对手机的令牌在接收器重启后仍可使用。

## 电脑文件下载

在电脑面板选定一个文件后，会生成 `screenrelay://download?v=1&url=<RFC3986 编码的电脑地址>&code=<下载码>`。下载码有效期为 30 分钟。

- 手机用 `HEAD /api/v1/download` 读取文件长度和版本，用 `GET /api/v1/download` 读取文件内容。两个请求都使用 `Authorization: Bearer <下载码>`。
- 文件名来自 `X-Filename`，采用 RFC 3986 UTF-8 百分号编码。完整长度为 HEAD 的 `Content-Length`。同一个下载码的 `ETag` 稳定。
- 续传使用 `Range: bytes=<已有字节数>-` 和 `If-Range: <ETag>`。返回 `206` 时，按 `Content-Range` 核对偏移和总长度后追加。返回 `200` 时，应从头写入完整文件，而非追加。
- `410` 表示下载码过期或原文件已变化、不可访问。重新选择文件并生成下载码即可发起新的下载。
- 下载码仅授权读取指定文件。配对和上传使用手机配对凭据。

## 上传示例

把地址、配对码和文件名换成本地值。

```sh
curl --fail-with-body http://192.168.1.25:8765/api/v1/uploads \
  -H "Authorization: Bearer YOUR_PAIRING_CODE" \
  -H "Content-Type: image/png" \
  -H "X-Filename: Screenshot.png" \
  -H "X-Media-Kind: screenshot" \
  -H "X-Upload-Id: test-device.sample-shot" \
  --data-binary @Screenshot.png
```
