import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import type { MediaKind } from './Media'

type UploadState = 'pending' | 'sent' | 'failed'
const STATE_VERSION = 2

export interface UploadItem {
  id: string
  target: string
  key: string
  uri: string
  filename: string
  kind: MediaKind
  staged: boolean
  state: UploadState
  attempts: number
  retryAt: number
  message: string
}

export interface SavedState {
  version: number
  deviceId: string
  endpoint: string
  token: string
  items: UploadItem[]
}

export interface SavedPairing {
  deviceId: string
  endpoint: string
  token: string
}

export class RelayStorage {
  private readonly statePath: string
  private readonly spoolPath: string

  constructor(directory: string) {
    this.statePath = directory + '/screenrelay.json'
    this.spoolPath = directory + '/screenrelay-queue'
    if (!fileIo.accessSync(this.spoolPath)) {
      fileIo.mkdirSync(this.spoolPath)
    }
  }

  private read(): SavedState | undefined {
    if (fileIo.accessSync(this.statePath)) {
      const state = JSON.parse(fileIo.readTextSync(this.statePath)) as SavedState
      if ((state.version !== 1 && state.version !== STATE_VERSION) || !Array.isArray(state.items)) {
        throw new Error('传输记录格式无法识别')
      }
      return state
    }
    return undefined
  }

  pairing(): SavedPairing | undefined {
    const state = this.read()
    if (state === undefined || !state.deviceId || !state.endpoint || !state.token) {
      return undefined
    }
    return { deviceId: state.deviceId, endpoint: state.endpoint, token: state.token }
  }

  load(): SavedState {
    const previous = this.read()
    const state: SavedState = {
      version: STATE_VERSION,
      deviceId: previous?.deviceId || util.generateRandomUUID(),
      endpoint: previous?.endpoint || '',
      token: previous?.token || '',
      // Older background discoveries had no private copy. Keep only user-selected uploads.
      items: previous?.items.filter((item: UploadItem): boolean => item.staged === true) || []
    }
    if (previous === undefined || previous.version !== STATE_VERSION || !previous.deviceId ||
      previous.items.length !== state.items.length) {
      this.save(state)
    }
    const pendingFiles = new Set<string>()
    for (const item of state.items) {
      if (item.state === 'pending') {
        pendingFiles.add(item.id)
      }
    }
    for (const name of fileIo.listFileSync(this.spoolPath)) {
      if (!pendingFiles.has(name)) {
        this.removeStaged(name)
      }
    }
    return state
  }

  save(state: SavedState): void {
    const temporaryPath = this.statePath + '.tmp'
    const output = fileIo.openSync(temporaryPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
    try {
      const bytes = new util.TextEncoder().encodeInto(JSON.stringify(state))
      const size = fileIo.writeSync(output.fd, bytes.buffer)
      if (size !== bytes.byteLength) {
        throw new Error('传输记录写入不完整')
      }
      fileIo.fsyncSync(output.fd)
    } finally {
      fileIo.closeSync(output)
    }
    fileIo.renameSync(temporaryPath, this.statePath)
  }

  stagedPath(id: string): string {
    return this.spoolPath + '/' + id
  }

  async stage(id: string, uri: string): Promise<string> {
    let file: fileIo.File
    try {
      // Read the URI granted by PhotoViewPicker directly. A full-library query
      // is unnecessary and can fail even though the user granted this file.
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
    } catch (error) {
      const code = (error as BusinessError).code
      throw new Error('无法读取所选文件' + (code ? '（' + code + '）' : '') +
        '。请重新选择，云端文件请先从相册下载。')
    }
    try {
      const path = this.stagedPath(id)
      try {
        await fileIo.copyFile(file.fd, path)
      } catch (_) {
        throw new Error('无法复制所选文件，请检查手机的剩余存储空间。')
      }
      if ((await fileIo.stat(path)).size <= 0) {
        throw new Error('所选文件没有可发送的数据。请先在相册中打开原文件。')
      }
      return file.name
    } finally {
      await fileIo.close(file)
    }
  }

  removeStaged(id: string): void {
    try {
      fileIo.unlinkSync(this.stagedPath(id))
    } catch (error) {
      // Completed files are also collected the next time the app opens.
      const code = (error as BusinessError).code
      if (code !== 13900002) {
        console.warn('ScreenRelay: staged file cleanup error ' + code)
      }
    }
  }
}
