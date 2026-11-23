import { photoAccessHelper } from '@kit.MediaLibraryKit'

export type MediaKind = 'screenshot' | 'screen-recording' | 'photo'

export function captureKey(uri: string): string {
  // The same library file can be returned with different display names.
  const match = /^file:\/\/media\/Photo\/(\d+)(?:[/?]|$)/i.exec(uri)
  return match ? 'photo-' + match[1] : uri
}

export async function selectCaptures(kind: MediaKind): Promise<string[]> {
  const options = new photoAccessHelper.PhotoSelectOptions()
  options.MIMEType = kind === 'screen-recording' ?
    photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
  options.maxSelectNumber = 25
  const result = await new photoAccessHelper.PhotoViewPicker().select(options)
  return result.photoUris
}
