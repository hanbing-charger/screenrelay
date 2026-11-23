import { fileIo } from '@kit.CoreFileKit'
import type { MediaKind } from './Media'

export function mediaType(name: string): string {
  const extension = name.slice(name.lastIndexOf('.') + 1).toLowerCase()
  switch (extension) {
    case 'png': return 'image/png'
    case 'jpg':
    case 'jpeg':
    case 'jpe':
    case 'jfif': return 'image/jpeg'
    case 'heic': return 'image/heic'
    case 'heics': return 'image/heic-sequence'
    case 'heif':
    case 'hif': return 'image/heif'
    case 'heifs': return 'image/heif-sequence'
    case 'avif': return 'image/avif'
    case 'webp': return 'image/webp'
    case 'gif': return 'image/gif'
    case 'bmp': return 'image/bmp'
    case 'jxl': return 'image/jxl'
    case 'tif':
    case 'tiff': return 'image/tiff'
    case 'dng': return 'image/x-adobe-dng'
    case 'mp4':
    case 'm4v': return 'video/mp4'
    case 'mov': return 'video/quicktime'
    case 'webm': return 'video/webm'
    case 'mkv': return 'video/x-matroska'
    case '3gp':
    case '3gpp': return 'video/3gpp'
    case '3g2':
    case '3gp2': return 'video/3gpp2'
    case 'avi': return 'video/x-msvideo'
    case 'mpeg':
    case 'mpg':
    case 'mpe':
    case 'm2v': return 'video/mpeg'
    case 'ts':
    case 'mts':
    case 'm2ts': return 'video/mp2t'
    case 'wmv': return 'video/x-ms-wmv'
    case 'flv': return 'video/x-flv'
    case 'ogv': return 'video/ogg'
    default: return 'application/octet-stream'
  }
}

function matches(bytes: Uint8Array, offset: number, signature: string): boolean {
  if (bytes.length < offset + signature.length) {
    return false
  }
  for (let index = 0; index < signature.length; index++) {
    if (bytes[offset + index] !== signature.charCodeAt(index)) {
      return false
    }
  }
  return true
}

function detectedExtension(bytes: Uint8Array, video: boolean): string {
  if (video) {
    if (matches(bytes, 4, 'ftyp')) {
      if (matches(bytes, 8, 'qt  ')) {
        return 'mov'
      }
      if (matches(bytes, 8, '3gp')) {
        return '3gp'
      }
      if (matches(bytes, 8, '3g2')) {
        return '3g2'
      }
      return 'mp4'
    }
    if (matches(bytes, 0, '\x1a\x45\xdf\xa3')) {
      return 'mkv'
    }
    if (matches(bytes, 0, 'RIFF') && matches(bytes, 8, 'AVI ')) {
      return 'avi'
    }
    return ''
  }
  if (matches(bytes, 0, '\x89PNG\r\n\x1a\n')) {
    return 'png'
  }
  if (matches(bytes, 0, '\xff\xd8\xff')) {
    return 'jpg'
  }
  if (matches(bytes, 0, 'GIF87a') || matches(bytes, 0, 'GIF89a')) {
    return 'gif'
  }
  if (matches(bytes, 0, 'RIFF') && matches(bytes, 8, 'WEBP')) {
    return 'webp'
  }
  if (matches(bytes, 0, 'BM')) {
    return 'bmp'
  }
  if (matches(bytes, 0, 'II\x2a\x00') || matches(bytes, 0, 'MM\x00\x2a')) {
    return 'tiff'
  }
  if (matches(bytes, 0, '\xff\x0a') || matches(bytes, 0, '\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a')) {
    return 'jxl'
  }
  if (matches(bytes, 4, 'ftyp')) {
    let extension = ''
    const ftypSize = bytes[0] * 16777216 + bytes[1] * 65536 + bytes[2] * 256 + bytes[3]
    const end = Math.min(bytes.length, ftypSize)
    for (let offset = 8; offset + 4 <= end; offset += 4) {
      if (offset === 12) {
        continue
      }
      if (matches(bytes, offset, 'avif') || matches(bytes, offset, 'avis')) {
        return 'avif'
      }
      if (matches(bytes, offset, 'heic') || matches(bytes, offset, 'heix') ||
        matches(bytes, offset, 'hevc') || matches(bytes, offset, 'hevx')) {
        extension = 'heic'
      }
      if (!extension && (matches(bytes, offset, 'mif1') || matches(bytes, offset, 'msf1'))) {
        extension = 'heif'
      }
    }
    return extension
  }
  return ''
}

function validFilename(name: string): boolean {
  return !!name && name.trim() !== '' && name !== '.' && name !== '..' && !/[\\/\x00-\x1f\x7f]/.test(name)
}

export function selectedFileName(uri: string, sourceName: string, stagedPath: string, kind: MediaKind): string {
  const uriPart = uri.split(/[?#]/)[0].split('/').pop() || ''
  let uriName = uriPart
  try {
    uriName = decodeURIComponent(uriPart)
  } catch (_) {
    // A literal percent in a picker filename is allowed.
  }
  if (kind === 'file') {
    for (const name of [sourceName, uriName]) {
      if (validFilename(name)) {
        return name
      }
    }
    throw new Error('无法读取所选文件的原始文件名，请从文件管理重新选择。')
  }
  const video = kind === 'video' || kind === 'screen-recording'
  const mimePrefix = video ? 'video/' : 'image/'
  for (const name of [uriName, sourceName]) {
    if (validFilename(name) && /\.[A-Za-z0-9]+$/.test(name) && mediaType(name).startsWith(mimePrefix)) {
      return name
    }
  }

  // A URI can expose an ID instead of a filename. Inspect the private copy, so reading
  // the format cannot move the picker descriptor used to copy the original bytes.
  const file = fileIo.openSync(stagedPath, fileIo.OpenMode.READ_ONLY)
  try {
    const header = new ArrayBuffer(64)
    const count = fileIo.readSync(file.fd, header)
    const extension = detectedExtension(new Uint8Array(header, 0, count), video)
    if (extension) {
      const basename = video ? '视频' : '图片'
      return basename + '-' + Date.now().toString() + '.' + extension
    }
  } finally {
    fileIo.closeSync(file)
  }
  throw new Error('无法识别所选媒体的格式。可使用「选择文件上传」发送原文件。')
}
