# 截屏快传接收接口

电脑上传服务默认监听 IPv4 TCP 8765。电脑控制台使用独立的本地端口，手机端应使用控制台显示的局域网地址。

- `GET /api/v1/health` 返回 `200` 和 `{"status":"ok","version":"0.1.0"}`，用于检查接收器地址是否可达。
- `POST /api/v1/uploads` 上传原始文件字节，需指定 `Content-Length`。文件名使用 RFC 3986 UTF-8 百分号编码后放入 `X-Filename`，类型放入 `X-Media-Kind`（`screenshot` 或 `screen-recording`），配对码放入 `Authorization: Bearer <token>`。建议设置实际 `Content-Type`。
- `X-Upload-Id` 可提供设备内稳定、设备间唯一的重试标识，支持 1 至 128 个 ASCII 字符 `A–Z a–z 0–9 . _ -`。
- 返回 `201` 表示保存完成，`200` 表示同一个 ID 对应的同一文件已保存。响应为 JSON，含 `id` 和 `name`。
- `401` 表示配对码错误，`409` 表示同一个 ID 已用于其他文件，`411` 表示缺少长度，`413` 表示超过文件上限，`415` 表示扩展名与支持的类型不符。网络错误和 `5xx` 可用同一个上传 ID 重试。

命令示例，需把地址、配对码和文件名换成本地值：

```sh
curl --fail-with-body http://192.168.1.25:8765/api/v1/uploads \
  -H "Authorization: Bearer YOUR_PAIRING_CODE" \
  -H "Content-Type: image/png" \
  -H "X-Filename: Screenshot.png" \
  -H "X-Media-Kind: screenshot" \
  -H "X-Upload-Id: test-device.sample-shot" \
  --data-binary @Screenshot.png
```
