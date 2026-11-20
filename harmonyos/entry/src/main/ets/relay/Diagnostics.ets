import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { hiAppEvent } from '@kit.PerformanceAnalysisKit'
import { MAX_DIAGNOSTIC_BYTES, sendDiagnostic } from './Transport'
import type { UploadResponse } from './Transport'
import type { SavedPairing } from './Storage'

const DAY_MS = 24 * 60 * 60 * 1000
const MAX_FRAMES = 50
const REPORT_FILENAME = /^harmony-(crash|freeze)-(\d{13})-([0-9a-f]{64})\.txt$/
const REDACT = /(?:bearer|authorization|token|password|passphrase|secret|api[_ -]?key|pairing[_ -]?code)/i

type DiagnosticKind = 'crash' | 'freeze'

interface NativeFrame {
  file?: string
  symbol?: string
  pc?: string
}

interface FreezeThread {
  stack?: string
  frames?: NativeFrame[]
}

interface NativeSignal {
  signo?: number
}

interface FaultException {
  name?: string
  stack?: string
  frames?: NativeFrame[]
  signal?: NativeSignal | number
}

interface FaultParameters {
  time?: number
  bundle_name?: string
  bundle_version?: string
  crash_type?: string
  pid?: number
  uuid?: string
  foreground?: boolean
  exception?: FaultException
  threads?: FreezeThread[]
}

export interface DiagnosticReport {
  id: string
  kind: DiagnosticKind
  occurredAt: number
  filename: string
  path: string
}

function fileComponent(path: string): string {
  if (/^(?:https?|screenrelay):/i.test(path)) {
    return ''
  }
  const component = path.replace(/\\/g, '/').split('/').pop() || ''
  return /^[A-Za-z0-9_.-]{1,120}\.(?:ets|ts|js|abc|so)(?:\.\d+)?$/.test(component) && !REDACT.test(component) ?
    component : ''
}

function safeLabel(label: string | undefined): string {
  if (typeof label !== 'string' || !/^[A-Za-z0-9_.$:~<>,+() -]{1,120}$/.test(label)) {
    return ''
  }
  return REDACT.test(label) ? '[已隐藏]' : label
}

function addJsFrames(rawStack: string | undefined, frames: string[]): void {
  if (typeof rawStack !== 'string') {
    return
  }
  // Use source basenames and locations only. The exception message and URLs may contain credentials or filenames.
  for (const line of rawStack.slice(0, 32000).split('\n')) {
    if (frames.length >= MAX_FRAMES) {
      return
    }
    const match = /^\s*at\s+([A-Za-z0-9_.$:~<>,+ -]{1,120})\s*\(([^\s()]+):(\d{1,8}):(\d{1,6})\)\s*$/.exec(line)
    if (match !== null) {
      const source = fileComponent(match[2])
      if (source) {
        frames.push('at ' + safeLabel(match[1].trim()) + ' (' + source + ':' + match[3] + ':' + match[4] + ')')
      }
    }
  }
}

function addNativeFrames(native: NativeFrame[] | undefined, frames: string[]): void {
  if (!Array.isArray(native)) {
    return
  }
  for (const frame of native.slice(0, MAX_FRAMES)) {
    if (frames.length >= MAX_FRAMES) {
      return
    }
    if (frame && typeof frame.file === 'string') {
      const source = fileComponent(frame.file)
      if (source) {
        const pc = typeof frame.pc === 'string' && /^(?:0x)?[0-9a-fA-F]{1,16}$/.test(frame.pc) ? frame.pc : ''
        const symbol = safeLabel(frame.symbol)
        frames.push(source + (pc ? ' pc ' + pc : '') + (symbol ? ' ' + symbol : ''))
      }
    }
  }
}

function caseId(kind: DiagnosticKind, time: number, params: FaultParameters): string {
  const uuid = typeof params.uuid === 'string' && /^[A-Za-z0-9-]{1,128}$/.test(params.uuid) ? params.uuid : ''
  const pid = typeof params.pid === 'number' && Number.isSafeInteger(params.pid) ? params.pid : 0
  const source = kind + '|' + time.toString() + '|' + pid.toString() + '|' + uuid
  const digest = cryptoFramework.createMd('SHA256')
  digest.updateSync({ data: new util.TextEncoder().encodeInto(source) })
  let id = ''
  for (const octet of digest.digestSync().data) {
    id += octet.toString(16).padStart(2, '0')
  }
  return id
}

function diagnosticText(kind: DiagnosticKind, time: number, id: string, params: FaultParameters): string {
  const lines = [
    '截屏快传诊断报告',
    '平台：HarmonyOS NEXT',
    '事件：' + (kind === 'crash' ? 'APP_CRASH' : 'APP_FREEZE'),
    '时间（UTC）：' + new Date(time).toISOString(),
    '事件编号：' + id
  ]
  const version = safeLabel(params.bundle_version)
  const crashType = safeLabel(params.crash_type)
  const exception = params.exception
  if (version) {
    lines.push('应用版本：' + version)
  }
  if (crashType) {
    lines.push('崩溃分类：' + crashType)
  }
  if (typeof params.foreground === 'boolean') {
    lines.push('应用在前台：' + (params.foreground ? '是' : '否'))
  }
  if (exception) {
    const name = safeLabel(exception.name)
    if (name) {
      lines.push('异常类型：' + name)
    }
    const signal = typeof exception.signal === 'number' ? exception.signal : exception.signal?.signo
    if (typeof signal === 'number' && Number.isSafeInteger(signal)) {
      lines.push('信号：' + signal.toString())
    }
  }

  const frames: string[] = []
  if (exception) {
    addJsFrames(exception.stack, frames)
    addNativeFrames(exception.frames, frames)
  }
  if (Array.isArray(params.threads)) {
    for (const thread of params.threads.slice(0, 4)) {
      if (thread) {
        addJsFrames(thread.stack, frames)
        addNativeFrames(thread.frames, frames)
      }
    }
  }
  if (frames.length > 0) {
    lines.push('', '调用栈（已筛选）', ...frames)
  } else {
    lines.push('', '本事件未提供可导出的调用栈。')
  }
  return lines.join('\n') + '\n'
}

export class DiagnosticReports {
  private readonly directory: string

  constructor(filesDir: string) {
    this.directory = filesDir + '/screenrelay-diagnostics'
    if (!fileIo.accessSync(this.directory)) {
      fileIo.mkdirSync(this.directory)
    }
  }

  collect(info: hiAppEvent.AppEventInfo, bundleName: string): void {
    let kind: DiagnosticKind
    if (info.name === hiAppEvent.event.APP_CRASH) {
      kind = 'crash'
    } else if (info.name === hiAppEvent.event.APP_FREEZE) {
      kind = 'freeze'
    } else {
      return
    }
    const params = info.params as FaultParameters
    const time = params.time
    const now = Date.now()
    if (typeof time !== 'number' || !Number.isSafeInteger(time) || time > now || time < now - DAY_MS ||
      (params.bundle_name && params.bundle_name !== bundleName)) {
      return
    }

    const id = caseId(kind, time, params)
    const filename = 'harmony-' + kind + '-' + time.toString() + '-' + id + '.txt'
    const path = this.directory + '/' + filename
    if (fileIo.accessSync(path)) {
      // Keep the first exact report generated for this occurrence, including across retry and app restarts.
      return
    }
    const bytes = new util.TextEncoder().encodeInto(diagnosticText(kind, time, id, params))
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_DIAGNOSTIC_BYTES) {
      return
    }
    const temporary = path + '.tmp'
    try {
      const output = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY)
      try {
        if (fileIo.writeSync(output.fd, bytes.buffer) !== bytes.byteLength) {
          throw new Error('诊断日志写入不完整')
        }
        fileIo.fsyncSync(output.fd)
      } finally {
        fileIo.closeSync(output)
      }
      fileIo.renameSync(temporary, path)
    } finally {
      if (fileIo.accessSync(temporary)) {
        fileIo.unlinkSync(temporary)
      }
    }
  }

  list(): DiagnosticReport[] {
    const now = Date.now()
    const reports: DiagnosticReport[] = []
    for (const filename of fileIo.listFileSync(this.directory)) {
      const match = REPORT_FILENAME.exec(filename)
      if (match === null) {
        continue
      }
      const path = this.directory + '/' + filename
      const occurredAt = Number(match[2])
      if (occurredAt < now - DAY_MS) {
        try {
          fileIo.unlinkSync(path)
        } catch (_) {
          // Expired reports remain excluded even if the device cannot clean them up.
        }
        continue
      }
      if (occurredAt <= now) {
        const kind: DiagnosticKind = match[1] === 'crash' ? 'crash' : 'freeze'
        reports.push({ id: match[3], kind: kind, occurredAt: occurredAt, filename: filename, path: path })
      }
    }
    return reports.sort((left: DiagnosticReport, right: DiagnosticReport): number => right.occurredAt - left.occurredAt)
  }

  async upload(report: DiagnosticReport, pairing: SavedPairing): Promise<UploadResponse> {
    const id = 'ohos-diagnostic-' + pairing.deviceId + '-' + report.id
    return sendDiagnostic(pairing.endpoint, pairing.token, report.path, report.filename, id)
  }
}

let watching = false

export function startDiagnostics(filesDir: string, bundleName: string): void {
  if (watching) {
    return
  }
  const reports = new DiagnosticReports(filesDir)
  reports.list()
  hiAppEvent.addWatcher({
    name: 'screenrelay_diagnostics',
    appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE] }],
    onReceive: (domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
      if (domain !== hiAppEvent.domain.OS) {
        return
      }
      for (const group of groups) {
        for (const info of group.appEventInfos) {
          try {
            reports.collect(info, bundleName)
          } catch (_) {
            // Delivery or storage failure must never interrupt capture and file transfers.
          }
        }
      }
    }
  })
  watching = true
}
