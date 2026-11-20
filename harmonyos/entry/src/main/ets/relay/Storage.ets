import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import type { MediaKind } from './Media'

type UploadState = 'pending' | 'sent' | 'failed'

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
  endpoint: string
  token: string
  autoSince: number
  items: UploadItem[]
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

  load(): SavedState {
    if (fileIo.accessSync(this.statePath)) {
      const state = JSON.parse(fileIo.readTextSync(this.statePath)) as SavedState
      if (state.version !== 1 || !Array.isArray(state.items)) {
        throw new Error('传输记录格式无法识别')
      }
      const pendingFiles = new Set<string>()
      for (const item of state.items) {
        if (item.staged && item.state === 'pending') {
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
    return { version: 1, endpoint: '', token: '', autoSince: 0, items: [] }
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

  async stage(id: string, uri: string): Promise<void> {
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)
    try {
      await fileIo.copyFile(file.fd, this.stagedPath(id))
    } catch (_) {
      this.removeStaged(id)
      throw new Error('复制文件失败，请检查剩余空间及相册访问权限')
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
