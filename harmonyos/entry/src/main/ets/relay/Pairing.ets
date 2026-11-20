import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { scanBarcode, scanCore } from '@kit.ScanKit'
import { normalizeEndpoint } from './Transport'

export interface PairingCode {
  endpoint: string
  code: string
}

const PAIRING_PREFIX = 'screenrelay://pair?'
const DOWNLOAD_PREFIX = 'screenrelay://download?'

function parseCode(value: string, prefix: string, invalid: string): PairingCode {
  if (!value.startsWith(prefix) || value.length > 2048) {
    throw new Error(invalid)
  }
  const fields = value.slice(prefix.length).split('&')
  if (fields.length !== 3 ||
    fields.some((field: string): boolean => !/^(v|url|code)=[A-Za-z0-9._~%\-]+$/.test(field))) {
    throw new Error(invalid)
  }
  const version = fields.find((field: string): boolean => field.startsWith('v='))
  const address = fields.find((field: string): boolean => field.startsWith('url='))
  const code = fields.find((field: string): boolean => field.startsWith('code='))
  if (version !== 'v=1' || address === undefined || code === undefined || !/^code=[A-Za-z0-9_-]{43}$/.test(code)) {
    throw new Error(invalid)
  }
  try {
    return { endpoint: normalizeEndpoint(decodeURIComponent(address.slice(4))), code: code.slice(5) }
  } catch (_) {
    throw new Error(invalid)
  }
}

export function parsePairingCode(value: string): PairingCode {
  return parseCode(value, PAIRING_PREFIX, '请扫描电脑端显示的截屏快传配对二维码。')
}

export function parseDownloadCode(value: string): PairingCode {
  return parseCode(value, DOWNLOAD_PREFIX, '请扫描电脑端显示的截屏快传文件二维码。')
}

async function scanCode(context: common.UIAbilityContext): Promise<string | undefined> {
  const options: scanBarcode.ScanOptions = {
    scanTypes: [scanCore.ScanType.QR_CODE],
    enableMultiMode: false,
    enableAlbum: true
  }
  let result: scanBarcode.ScanResult
  try {
    result = await scanBarcode.startScanForResult(context, options)
  } catch (error) {
    if ((error as BusinessError).code === 1000500002) {
      return undefined
    }
    throw new Error('无法打开系统扫码。请检查相机是否可用。')
  }
  return result.originalValue
}

export async function scanPairingCode(context: common.UIAbilityContext): Promise<PairingCode | undefined> {
  const value = await scanCode(context)
  return value === undefined ? undefined : parsePairingCode(value)
}

export async function scanDownloadCode(context: common.UIAbilityContext): Promise<PairingCode | undefined> {
  const value = await scanCode(context)
  return value === undefined ? undefined : parseDownloadCode(value)
}
