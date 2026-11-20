import { url } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { rcp } from '@kit.RemoteCommunicationKit'
import type { UploadItem } from './Storage'

const LONG_TRANSFER_MS = 30 * 60 * 1000

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
