import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit'
import { dataSharePredicates } from '@kit.ArkData'
import { photoAccessHelper } from '@kit.MediaLibraryKit'

export type MediaKind = 'screenshot' | 'screen-recording' | 'photo'

export interface Capture {
  uri: string
  filename: string
  kind: MediaKind
}

const READ_MEDIA: Permissions = 'ohos.permission.READ_IMAGEVIDEO'
const SCREENSHOT_NAME = /^(screenshots?|screen[_ -]?shots?|截屏|截图)[_ -]?[0-9]/i
const RECORDING_NAME = /^(screen[_ -]?record(?:s|er|ing)?|录屏|屏幕录制)[_ -]?[0-9]/i

export function captureKind(filename: string, type: photoAccessHelper.PhotoType): MediaKind | undefined {
  if (type === photoAccessHelper.PhotoType.IMAGE && SCREENSHOT_NAME.test(filename)) {
    return 'screenshot'
  }
  if (type === photoAccessHelper.PhotoType.VIDEO && RECORDING_NAME.test(filename)) {
    return 'screen-recording'
  }
  return undefined
}

export function captureKey(uri: string): string {
  // Picker and automatic queries can return different names for the same library ID.
  const match = /^file:\/\/media\/Photo\/(\d+)(?:[/?]|$)/i.exec(uri)
  return match ? 'photo-' + match[1] : uri
}

export async function requestMediaAccess(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [READ_MEDIA])
    return result.authResults[0] === 0
  } catch (_) {
    // The default signing profile deliberately omits the Huawei-restricted permission.
    return false
  }
}

export async function getNewCaptures(context: common.UIAbilityContext, since: number): Promise<Capture[]> {
  const agent = photoAccessHelper.getPhotoAccessHelper(context)
  const predicates = new dataSharePredicates.DataSharePredicates()
  predicates.orderByDesc(photoAccessHelper.PhotoKeys.DATE_ADDED)
  const options: photoAccessHelper.FetchOptions = {
    fetchColumns: [photoAccessHelper.PhotoKeys.DATE_ADDED, photoAccessHelper.PhotoKeys.DATE_ADDED_MS],
    predicates: predicates
  }
  const result = await agent.getAssets(options)
  try {
    const captures: Capture[] = []
    const count = result.getCount()
    const firstSecond = Math.floor(since / 1000)
    for (let index = 0; index < count; index++) {
      const asset = await result.getObjectByPosition(index)
      const addedSecond = asset.get(photoAccessHelper.PhotoKeys.DATE_ADDED)
      if (typeof addedSecond === 'number' && addedSecond < firstSecond) {
        break
      }
      const added = asset.get(photoAccessHelper.PhotoKeys.DATE_ADDED_MS)
      if (typeof added !== 'number' || added < since) {
        continue
      }
      const kind = captureKind(asset.displayName, asset.photoType)
      if (kind !== undefined) {
        captures.push({ uri: asset.uri, filename: asset.displayName, kind: kind })
      }
    }
    return captures
  } finally {
    result.close()
  }
}

export async function selectCaptures(kind: MediaKind): Promise<string[]> {
  const options = new photoAccessHelper.PhotoSelectOptions()
  options.MIMEType = kind === 'screen-recording' ?
    photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
  options.maxSelectNumber = 25
  const result = await new photoAccessHelper.PhotoViewPicker().select(options)
  return result.photoUris
}
