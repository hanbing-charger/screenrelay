import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { captureKey } from './Media'
import type { MediaKind } from './Media'
import { selectedFileName } from './MediaFormat'
import { scanPairingCode } from './Pairing'
import { RelayStorage } from './Storage'
import type { SavedState, UploadItem } from './Storage'
import { checkReceiver, normalizeEndpoint, pairReceiver, sendCapture } from './Transport'
import type { UploadResponse } from './Transport'

export interface RelayStatus {
  endpoint: string
  token: string
  pending: number
  sent: number
  failed: number
  otherReceivers: number
  message: string
}

export interface SelectedResult {
  remaining: string[]
  message: string
}

const RETRY_INTERVAL_MS = 6000
const MAX_RETRY_DELAY_MS = 5 * 60 * 1000

export class Relay {
  private readonly context: common.UIAbilityContext
  private readonly onChange: (status: RelayStatus) => void
  private store: RelayStorage
  private state: SavedState
  private foreground: boolean = false
  private timer: number = -1
  private running: boolean = false
  private blockedEndpoint: string = ''
  private receiverRetryAt: number = 0
  private message: string = ''

  constructor(context: common.UIAbilityContext, onChange: (status: RelayStatus) => void) {
    this.context = context
    this.onChange = onChange
    this.store = new RelayStorage(context.filesDir)
    this.state = this.store.load()
  }

  status(): RelayStatus {
    let pending = 0
    let sent = 0
    let failed = 0
    let otherReceivers = 0
    for (const item of this.state.items) {
      if (item.target !== this.state.endpoint) {
        if (item.state === 'pending') {
          otherReceivers += 1
        }
        continue
      }
      switch (item.state) {
        case 'pending': pending += 1; break
        case 'sent': sent += 1; break
        case 'failed': failed += 1; break
      }
    }
    return {
      endpoint: this.state.endpoint,
      token: this.state.token,
      pending: pending,
      sent: sent,
      failed: failed,
      otherReceivers: otherReceivers,
      message: this.message
    }
  }

  setForeground(value: boolean): void {
    this.foreground = value
    if (value && this.timer < 0) {
      this.timer = setInterval(() => { this.run() }, RETRY_INTERVAL_MS)
      this.run()
    }
    if (!value && this.timer >= 0) {
      clearInterval(this.timer)
      this.timer = -1
    }
  }

  saveSettings(address: string, rawToken: string): void {
    const endpoint = normalizeEndpoint(address)
    const token = rawToken.trim()
    if (!/^[!-~]{1,256}$/.test(token)) {
      throw new Error('请输入电脑端显示的配对令牌')
    }
    this.commit(endpoint, token, this.resetItemsFor(endpoint))
    this.blockedEndpoint = ''
    this.receiverRetryAt = 0
    this.notify('')
    this.run()
  }

  async checkConnection(address: string): Promise<boolean> {
    return checkReceiver(normalizeEndpoint(address))
  }

  async pairByScan(): Promise<boolean> {
    const pairing = await scanPairingCode(this.context)
    if (pairing === undefined) {
      return false
    }
    const model = (deviceInfo.marketName || deviceInfo.productModel || '').trim() || '鸿蒙设备'
    const token = await pairReceiver(pairing.endpoint, pairing.code, this.state.deviceId, model.slice(0, 80))
    this.saveSettings(pairing.endpoint, token)
    return true
  }

  async addSelected(uris: string[], kind: MediaKind): Promise<SelectedResult> {
    const endpoint = this.requireReceiver()
    let added = 0
    let skipped = 0
    let failure = ''
    const remaining: string[] = []
    for (const uri of uris) {
      if (this.state.endpoint !== endpoint) {
        remaining.push(uri)
        failure = '配对电脑已变更，请重新发送所选文件。'
        continue
      }
      const item = this.newItem(endpoint, uri, kind)
      if (this.contains(endpoint, item.key)) {
        skipped += 1
        continue
      }
      try {
        const sourceName = await this.store.stage(item.id, uri)
        item.filename = selectedFileName(uri, sourceName, this.store.stagedPath(item.id), kind)
        if (this.state.endpoint !== endpoint) {
          throw new Error('配对电脑已变更，请重新发送所选文件。')
        }
        if (this.contains(endpoint, item.key)) {
          this.store.removeStaged(item.id)
          skipped += 1
          continue
        }
        try {
          this.append([item])
        } catch (_) {
          throw new Error('无法保存发送队列')
        }
        added += 1
      } catch (error) {
        this.store.removeStaged(item.id)
        remaining.push(uri)
        failure = (error as BusinessError).message || '无法读取或保存所选文件。'
      }
    }
    let message = '已加入 ' + added + ' 个文件，应用将继续发送。'
    if (skipped > 0) {
      message += skipped + ' 个已在传输记录中。'
    }
    if (remaining.length > 0) {
      message += remaining.length + ' 个未加入队列。' + failure
    }
    this.notify(message)
    this.run()
    return { remaining: remaining, message: message }
  }

  retry(): void {
    this.requireReceiver()
    this.commit(this.state.endpoint, this.state.token, this.resetItemsFor(this.state.endpoint))
    this.blockedEndpoint = ''
    this.receiverRetryAt = 0
    this.notify('正在检查待发送文件。')
    this.run()
  }

  private resetItemsFor(endpoint: string): UploadItem[] {
    return this.state.items.map((item: UploadItem): UploadItem => {
      if (item.target === endpoint && item.state === 'pending' && item.retryAt > 0) {
        return this.withResult(item, 'pending', 0, 0, '')
      }
      return item
    })
  }

  private requireReceiver(): string {
    if (!this.state.endpoint || !this.state.token) {
      throw new Error('请先保存接收地址和配对令牌')
    }
    return this.state.endpoint
  }

  private notify(message: string): void {
    this.message = message
    this.onChange(this.status())
  }

  private commit(endpoint: string, token: string, items: UploadItem[]): void {
    const next: SavedState = {
      version: this.state.version, deviceId: this.state.deviceId, endpoint: endpoint, token: token, items: items
    }
    this.store.save(next)
    this.state = next
  }

  private append(items: UploadItem[]): void {
    this.commit(this.state.endpoint, this.state.token, this.state.items.concat(items))
  }

  private contains(endpoint: string, key: string): boolean {
    return this.state.items.some((item: UploadItem): boolean =>
      item.target === endpoint && item.key === key && item.state !== 'failed')
  }

  private newItem(endpoint: string, uri: string, kind: MediaKind): UploadItem {
    return {
      id: util.generateRandomUUID(),
      target: endpoint,
      key: captureKey(uri),
      uri: uri,
      filename: '',
      kind: kind,
      staged: true,
      state: 'pending',
      attempts: 0,
      retryAt: 0,
      message: ''
    }
  }

  private withResult(item: UploadItem, state: 'pending' | 'sent' | 'failed', attempts: number, retryAt: number,
    message: string): UploadItem {
    return {
      id: item.id,
      target: item.target,
      key: item.key,
      uri: item.uri,
      filename: item.filename,
      kind: item.kind,
      staged: item.staged,
      state: state,
      attempts: attempts,
      retryAt: retryAt,
      message: message
    }
  }

  private record(item: UploadItem): void {
    const items = this.state.items.map((current: UploadItem): UploadItem => current.id === item.id ? item : current)
    this.commit(this.state.endpoint, this.state.token, items)
    if (item.staged && item.state !== 'pending') {
      this.store.removeStaged(item.id)
    }
  }

  private delay(item: UploadItem, message: string, receiverRetryAfter?: string): void {
    const attempts = item.attempts + 1
    const now = Date.now()
    let delay = RETRY_INTERVAL_MS * Math.pow(2, Math.min(attempts, 8))
    if (receiverRetryAfter !== undefined) {
      const hint = receiverRetryAfter.trim()
      const suggested = /^\d+$/.test(hint) ? Number(hint) * 1000 : Date.parse(hint) - now
      if (suggested >= 0) {
        delay = Math.max(1000, suggested)
      }
    }
    const retryAt = now + Math.min(MAX_RETRY_DELAY_MS, delay)
    this.record(this.withResult(item, 'pending', attempts, retryAt, message))
    if (receiverRetryAfter !== undefined && item.target === this.state.endpoint) {
      this.receiverRetryAt = retryAt
    }
    this.notify(message)
  }

  private reject(item: UploadItem, message: string): void {
    this.record(this.withResult(item, 'failed', item.attempts, 0, message))
    this.notify(item.filename + ' · ' + message)
  }

  private async upload(item: UploadItem, token: string): Promise<void> {
    const source = this.store.stagedPath(item.id)
    this.notify('正在发送 ' + item.filename)
    let response: UploadResponse
    try {
      response = await sendCapture(item, source, token)
    } catch (error) {
      const code = (error as BusinessError).code
      if (code === 13900002) {
        this.reject(item, '原文件已不存在。')
      } else if (code === 1007900006 || code === 1007900007 || code === 1007900028) {
        this.delay(item, '暂时无法连接电脑，队列将自动重试。', '')
      } else {
        this.delay(item, '暂时无法读取文件或连接电脑，将自动重试。')
      }
      return
    }
    switch (response.status) {
      case 200:
      case 201:
        this.record(this.withResult(item, 'sent', item.attempts, 0, ''))
        this.notify('已发送 ' + item.filename)
        return
      case 401:
      case 403:
        if (item.target === this.state.endpoint && token === this.state.token) {
          this.blockedEndpoint = item.target
          this.notify('电脑拒绝配对令牌。请核对后重新保存。')
        }
        return
      case 413:
        this.reject(item, '文件超出电脑接收上限。')
        return
      case 409:
        this.reject(item, '电脑报告文件记录冲突。')
        return
      case 400:
        this.reject(item, item.kind === 'photo' ?
          '电脑拒绝图片上传请求（HTTP 400）。请确认电脑端已更新到支持图片传输的版本。' :
          '电脑拒绝了上传请求（HTTP 400）。')
        return
      case 415:
        this.reject(item, '电脑无法接收此文件格式（HTTP 415）。请更新电脑端或选择其他格式。')
        return
      case 411:
        this.reject(item, '电脑未收到文件长度（HTTP 411），请重新选择原文件后发送。')
        return
      case 429:
      case 503:
        this.delay(item, '电脑接收端当前繁忙，队列将自动重试。', response.retryAfter)
        return
      default:
        this.delay(item, '电脑暂时未接收文件（HTTP ' + response.status + '），将自动重试。')
    }
  }

  private async run(): Promise<void> {
    if (!this.foreground || this.running || !this.state.endpoint || !this.state.token) {
      return
    }
    this.running = true
    const endpoint = this.state.endpoint
    try {
      while (this.foreground && this.state.endpoint === endpoint && this.blockedEndpoint !== endpoint) {
        const readyAt = Date.now()
        if (readyAt < this.receiverRetryAt) {
          break
        }
        const next = this.state.items.find((item: UploadItem): boolean =>
          item.staged && item.target === endpoint && item.state === 'pending' && item.retryAt <= readyAt)
        if (next === undefined) {
          break
        }
        await this.upload(next, this.state.token)
      }
    } catch (_) {
      this.notify('无法更新传输队列，请检查设备剩余存储空间。')
    } finally {
      this.running = false
    }
  }
}
