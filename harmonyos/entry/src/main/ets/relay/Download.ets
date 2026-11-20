import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo, picker } from '@kit.CoreFileKit'
import { rcp } from '@kit.RemoteCommunicationKit'
import type { PairingCode } from './Pairing'
import { createSession } from './Transport'

const DOWNLOAD_TIMEOUT_MS = 30 * 60 * 1000
const ATTEMPTS = 3
const MAX_DISCARDED_BYTES = 64 * 1024
const SHARING_EXPIRED = '文件分享已过期或电脑上的文件已更改，请重新生成二维码。'
const INVALID_RESPONSE = '电脑返回的文件信息不一致，请重新生成二维码。'
const STORAGE_ERROR = '无法保存文件，请检查手机的剩余存储空间。'

interface DownloadMetadata {
  name: string
  length: number
  etag: string
}

export interface ReceivedFile {
  name: string
  path: string
  savedAt: number
}

function header(headers: rcp.ResponseHeaders, name: string): string {
  for (const key of Object.keys(headers)) {
    const value = headers[key]
    if (key.toLowerCase() === name && typeof value === 'string') {
      return value.trim()
    }
  }
  return ''
}

function authHeaders(code: string): rcp.RequestHeaders {
  return { 'Authorization': 'Bearer ' + code, 'Accept-Encoding': 'identity' }
}

function byteLength(value: string): number {
  return new util.TextEncoder().encodeInto(value).byteLength
}

function fileName(headers: rcp.ResponseHeaders): string {
  const name = decodeURIComponent(header(headers, 'x-filename'))
  if (!name.trim() || name === '.' || name === '..' || /[\\/\x00-\x1f\x7f]/.test(name) || byteLength(name) > 255) {
    throw new Error('电脑返回的文件名无效。')
  }
  return name
}

function checkShareStatus(status: number): void {
  if (status === 410) {
    throw new Error(SHARING_EXPIRED)
  }
  if (status === 401 || status === 403) {
    throw new Error('电脑拒绝了此文件分享，请重新扫描。')
  }
}

async function getMetadata(share: PairingCode): Promise<DownloadMetadata> {
  const session = createSession(10000)
  try {
    const request = new rcp.Request(share.endpoint + '/api/v1/download', 'HEAD', authHeaders(share.code))
    let response: rcp.Response
    try {
      response = await session.fetch(request)
    } catch (_) {
      throw new Error('无法连接电脑。请确认两台设备在同一局域网。')
    }
    checkShareStatus(response.statusCode)
    if (response.statusCode !== 200) {
      throw new Error('电脑暂时无法分享文件，请稍后重新扫描。')
    }
    const rawLength = header(response.headers, 'content-length')
    const length = Number(rawLength)
    const etag = header(response.headers, 'etag')
    if (!/^\d+$/.test(rawLength) || !Number.isSafeInteger(length) || !/^"[\x21\x23-\x7e]{1,126}"$/.test(etag)) {
      throw new Error(INVALID_RESPONSE)
    }
    try {
      return { name: fileName(response.headers), length: length, etag: etag }
    } catch (_) {
      throw new Error('电脑返回的文件名无效。')
    }
  } finally {
    session.close()
  }
}

function matchesDownload(headers: rcp.ResponseHeaders, metadata: DownloadMetadata, offset: number): boolean {
  const encoding = header(headers, 'content-encoding').toLowerCase()
  const range = offset > 0 ? 'bytes ' + offset + '-' + (metadata.length - 1) + '/' + metadata.length : ''
  return (encoding === '' || encoding === 'identity') &&
    header(headers, 'etag') === metadata.etag &&
    header(headers, 'content-length') === (metadata.length - offset).toString() &&
    header(headers, 'content-range') === range
}

async function receivePart(share: PairingCode, metadata: DownloadMetadata, temporary: string,
  progress: (name: string, received: number, length: number) => void): Promise<boolean> {
  const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND)
  try {
    const offset = fileIo.statSync(file.fd).size
    let received = offset
    let discarded = 0
    let lastProgress = 0
    let headersMatched = false
    let headersReceived = false
    let bodyExceeded = false
    let writeFailed = false
    const events: rcp.HttpEventsHandler = {
      onHeaderReceive: (headers: rcp.ResponseHeaders): void => {
        headersReceived = true
        headersMatched = matchesDownload(headers, metadata, offset)
      }
    }
    const stream: rcp.SyncWriteStream = {
      writeSync: (data: ArrayBuffer): number => {
        if ((headersReceived && !headersMatched) || data.byteLength > metadata.length - received) {
          if (!headersReceived || headersMatched) {
            bodyExceeded = true
          }
          discarded += data.byteLength
          return discarded <= MAX_DISCARDED_BYTES ? data.byteLength : 0
        }
        try {
          if (fileIo.writeSync(file.fd, data) !== data.byteLength) {
            writeFailed = true
            return 0
          }
        } catch (_) {
          writeFailed = true
          return 0
        }
        received += data.byteLength
        const now = Date.now()
        if (received === metadata.length || now - lastProgress >= 400) {
          lastProgress = now
          progress(metadata.name, received, metadata.length)
        }
        return data.byteLength
      }
    }
    const headers = authHeaders(share.code)
    if (offset > 0) {
      headers['Range'] = 'bytes=' + offset + '-'
      headers['If-Range'] = metadata.etag
    }
    const request = new rcp.Request(share.endpoint + '/api/v1/download', 'GET', headers)
    const destination: rcp.DownloadToStream = { kind: 'stream', stream: stream }
    request.destination = destination
    const session = createSession(DOWNLOAD_TIMEOUT_MS, events)
    let response: rcp.Response
    try {
      try {
        response = await session.fetch(request)
      } catch (_) {
        if (writeFailed) {
          throw new Error(STORAGE_ERROR)
        }
        if (bodyExceeded || discarded > MAX_DISCARDED_BYTES) {
          throw new Error(INVALID_RESPONSE)
        }
        if (!headersMatched || received === metadata.length) {
          // Keep only a verified partial body. A full body still needs a successful HTTP response.
          fileIo.truncateSync(file.fd, offset)
        }
        return false
      }
    } finally {
      session.close()
    }

    checkShareStatus(response.statusCode)
    if (writeFailed) {
      throw new Error(STORAGE_ERROR)
    }
    if (response.statusCode === 408 || response.statusCode === 429 || response.statusCode >= 500) {
      fileIo.truncateSync(file.fd, offset)
      return false
    }
    if (response.statusCode !== (offset > 0 ? 206 : 200) || bodyExceeded ||
      !matchesDownload(response.headers, metadata, offset)) {
      throw new Error(INVALID_RESPONSE)
    }
    if (received !== fileIo.statSync(file.fd).size) {
      throw new Error(STORAGE_ERROR)
    }
    if (received !== metadata.length) {
      return false
    }
    fileIo.fsyncSync(file.fd)
    return true
  } finally {
    fileIo.closeSync(file)
  }
}

function makeDirectory(path: string): void {
  if (!fileIo.accessSync(path)) {
    fileIo.mkdirSync(path)
  }
}

function removeTemporary(path: string): void {
  try {
    fileIo.unlinkSync(path)
  } catch (_) {
    // A suspended session's private temporary files are cleared when the app opens again.
  }
}

export class DownloadReceiver {
  readonly directory: string
  private readonly partialDirectory: string

  constructor(filesDir: string) {
    this.directory = filesDir + '/received'
    this.partialDirectory = filesDir + '/screenrelay-incoming'
    makeDirectory(this.directory)
    makeDirectory(this.partialDirectory)
    for (const name of fileIo.listFileSync(this.partialDirectory)) {
      if (/^[0-9a-f-]{36}\.part$/i.test(name)) {
        removeTemporary(this.partialDirectory + '/' + name)
      }
    }
  }

  list(): ReceivedFile[] {
    const received: ReceivedFile[] = []
    for (const name of fileIo.listFileSync(this.directory)) {
      const path = this.directory + '/' + name
      const stat = fileIo.statSync(path)
      if (stat.isFile()) {
        received.push({ name: name, path: path, savedAt: stat.mtime })
      }
    }
    return received.sort((left: ReceivedFile, right: ReceivedFile): number => right.savedAt - left.savedAt)
  }

  async receive(share: PairingCode,
    progress: (name: string, received: number, length: number) => void): Promise<ReceivedFile> {
    const metadata = await getMetadata(share)
    const temporary = this.partialDirectory + '/' + util.generateRandomUUID() + '.part'
    try {
      progress(metadata.name, 0, metadata.length)
      for (let attempt = 1; attempt <= ATTEMPTS; attempt += 1) {
        if (await receivePart(share, metadata, temporary, progress)) {
          const path = this.availablePath(metadata.name)
          fileIo.renameSync(temporary, path)
          return { name: path.slice(this.directory.length + 1), path: path, savedAt: Date.now() }
        }
        if (attempt < ATTEMPTS) {
          await new Promise<void>((resolve) => { setTimeout(() => { resolve() }, attempt * 1200) })
        }
      }
      throw new Error('接收中断，请确认网络连接后重新扫码。')
    } finally {
      removeTemporary(temporary)
    }
  }

  private availablePath(name: string): string {
    const original = this.directory + '/' + name
    if (!fileIo.accessSync(original)) {
      return original
    }
    const dot = name.lastIndexOf('.')
    const stem = dot > 0 ? name.slice(0, dot) : name
    const extension = dot > 0 ? name.slice(dot) : ''
    for (let number = 2; number < 1000; number += 1) {
      const alternative = stem + ' (' + number + ')' + extension
      if (byteLength(alternative) > 255) {
        break
      }
      const path = this.directory + '/' + alternative
      if (!fileIo.accessSync(path)) {
        return path
      }
    }
    return this.directory + '/' + util.generateRandomUUID() + (byteLength(extension) < 99 ? extension : '')
  }
}

export async function exportReceived(context: common.UIAbilityContext, file: ReceivedFile): Promise<boolean> {
  const options = new picker.DocumentSaveOptions()
  options.newFileNames = [file.name]
  const uris = await new picker.DocumentViewPicker(context).save(options)
  if (uris.length === 0) {
    return false
  }
  const source = await fileIo.open(file.path, fileIo.OpenMode.READ_ONLY)
  try {
    const destination = await fileIo.open(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
    try {
      await fileIo.copyFile(source.fd, destination.fd)
    } finally {
      await fileIo.close(destination)
    }
  } finally {
    await fileIo.close(source)
  }
  return true
}
