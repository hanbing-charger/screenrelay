import { url } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { rcp } from '@kit.RemoteCommunicationKit'
import type { UploadItem } from './Storage'

const LONG_TRANSFER_MS = 30 * 60 * 1000

interface PairingRequest {
  pairingCode: string
  deviceId: string
  deviceName: string
}

interface PairingResponse {
  token: string
}

export function normalizeEndpoint(input: string): string {
  const value = input.trim()
  if (!/^https?:\/\/[^/?#\\\s@]+\/?$/i.test(value)) {
    throw new Error('请输入电脑端显示的完整地址')
  }
  const parsed = url.URL.parseURL(value)
  if (!parsed.hostname || parsed.username || parsed.password) {
    throw new Error('电脑地址无效')
  }
  return parsed.protocol + '//' + parsed.host
}

function createSession(timeout: number): rcp.Session {
  const transfer: rcp.TransferConfiguration = {
    autoRedirect: false,
    timeout: { connectMs: 8000, transferMs: timeout }
  }
  return rcp.createSession({ requestConfiguration: { transfer: transfer } })
}

function filenameHeader(name: string): string {
  return encodeURIComponent(name).replace(/[!'()*]/g, (value: string): string => {
    return '%' + value.charCodeAt(0).toString(16).toUpperCase()
  })
}

function mediaType(name: string): string {
  const extension = name.slice(name.lastIndexOf('.') + 1).toLowerCase()
  switch (extension) {
    case 'png': return 'image/png'
    case 'jpg':
    case 'jpeg': return 'image/jpeg'
    case 'heic': return 'image/heic'
    case 'heif': return 'image/heif'
    case 'webp': return 'image/webp'
    case 'gif': return 'image/gif'
    case 'mp4':
    case 'm4v': return 'video/mp4'
    case 'mov': return 'video/quicktime'
    case 'webm': return 'video/webm'
    default: return 'application/octet-stream'
  }
}

export async function checkReceiver(endpoint: string): Promise<boolean> {
  const session = createSession(10000)
  try {
    const result = await session.get(endpoint + '/api/v1/health')
    return result.statusCode === 200
  } finally {
    session.close()
  }
}

export async function pairReceiver(endpoint: string, code: string, deviceId: string,
  deviceName: string): Promise<string> {
  const headers: rcp.RequestHeaders = { 'Content-Type': 'application/json; charset=utf-8' }
  const body: PairingRequest = { pairingCode: code, deviceId: deviceId, deviceName: deviceName }
  const request = new rcp.Request(endpoint + '/api/v1/pair', 'POST', headers, JSON.stringify(body))
  const session = createSession(10000)
  try {
    let result: rcp.Response
    try {
      result = await session.fetch(request)
    } catch (_) {
      throw new Error('无法连接电脑。请确认接收端已启动，且两台设备在同一局域网。')
    }
    if (result.statusCode === 401) {
      throw new Error('二维码无效或已过期。请在电脑端刷新二维码后重试。')
    }
    if (result.statusCode !== 200 && result.statusCode !== 201) {
      throw new Error('电脑未接受配对请求。请检查接收端后重试。')
    }
    try {
      const payload = JSON.parse(result.toString() || '') as PairingResponse
      if (typeof payload.token === 'string' && /^[!-~]{1,256}$/.test(payload.token)) {
        return payload.token
      }
    } catch (_) {
      throw new Error('电脑返回了无效的配对信息。')
    }
    throw new Error('电脑返回了无效的配对信息。')
  } finally {
    session.close()
  }
}

export async function sendCapture(item: UploadItem, source: string, token: string): Promise<number> {
  const file = await fileIo.open(source, fileIo.OpenMode.READ_ONLY)
  try {
    const stat = await fileIo.stat(file.fd)
    if (stat.size <= 0) {
      throw new Error('文件尚未写入完成')
    }

    const headers: rcp.RequestHeaders = {
      'Authorization': 'Bearer ' + token,
      'Content-Type': mediaType(item.filename),
      'Content-Length': stat.size.toString(),
      'X-Filename': filenameHeader(item.filename),
      'X-Media-Kind': item.kind,
      'X-Upload-Id': 'ohos-' + item.id
    }
    const body = new rcp.UploadFromFile(file.fd)
    const request = new rcp.Request(item.target + '/api/v1/uploads', 'POST', headers, body)
    const session = createSession(LONG_TRANSFER_MS)
    try {
      const result = await session.fetch(request)
      return result.statusCode
    } finally {
      session.close()
    }
  } finally {
    await fileIo.close(file)
  }
}
