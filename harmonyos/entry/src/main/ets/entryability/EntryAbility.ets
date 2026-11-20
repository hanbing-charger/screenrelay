import { UIAbility } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { startDiagnostics } from '../relay/Diagnostics'

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    try {
      startDiagnostics(this.context.filesDir, this.context.abilityInfo.bundleName)
    } catch (_) {
      hilog.warn(0x1210, 'ScreenRelay', 'Unable to register the system diagnostic watcher')
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(0x1210, 'ScreenRelay', 'Page load failed: %{public}d', error.code)
      }
    })
  }
}
