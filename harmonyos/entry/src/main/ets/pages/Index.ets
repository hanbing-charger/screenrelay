import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { selectCaptures } from '../relay/Media'
import type { MediaKind } from '../relay/Media'
import { Relay } from '../relay/Relay'
import type { RelayStatus } from '../relay/Relay'

const INK = '#102438'
const SUBTLE = '#496276'
const ACCENT = '#006658'
const BACKGROUND = '#F2F7F6'
const BORDER = '#DCE8E7'

@Entry
@Component
struct Index {
  @State private address: string = ''
  @State private token: string = ''
  @State private paired: boolean = false
  @State private detecting: boolean = false
  @State private busy: boolean = false
  @State private pending: number = 0
  @State private sent: number = 0
  @State private failed: number = 0
  @State private otherReceivers: number = 0
  @State private selectedUris: string[] = []
  @State private message: string = '输入电脑上的接收地址和配对令牌。'
  private selectedKind: MediaKind = 'screenshot'
  private relay: Relay | undefined = undefined

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      this.relay = new Relay(context, (status: RelayStatus): void => this.applyStatus(status))
      const status = this.relay.status()
      this.address = status.endpoint
      this.token = status.token
      this.applyStatus(status)
    } catch (_) {
      this.message = '无法打开本地传输记录。请检查设备剩余空间后重新打开应用。'
    }
  }

  onPageShow(): void {
    this.relay?.setForeground(true)
  }

  onPageHide(): void {
    this.relay?.setForeground(false)
  }

  aboutToDisappear(): void {
    this.relay?.setForeground(false)
  }

  private applyStatus(status: RelayStatus): void {
    this.paired = Boolean(status.endpoint && status.token)
    this.detecting = status.detecting
    this.pending = status.pending
    this.sent = status.sent
    this.failed = status.failed
    this.otherReceivers = status.otherReceivers
    this.message = status.message
  }

  private async action(task: () => Promise<void>): Promise<void> {
    if (this.busy) {
      return
    }
    this.busy = true
    try {
      await task()
    } catch (error) {
      this.message = (error as BusinessError).message || '操作未完成，请重试。'
    } finally {
      this.busy = false
    }
  }

  private async saveConfiguration(): Promise<void> {
    this.relay?.saveSettings(this.address, this.token)
  }

  private async checkConnection(): Promise<void> {
    try {
      const available = await this.relay?.checkConnection(this.address)
      this.message = available ? '已连通电脑。发送时会验证令牌。' : '电脑没有返回可用状态。'
    } catch (_) {
      this.message = '连接失败。请核对地址，确认手机和电脑在同一局域网。'
    }
  }

  private async changeDetection(): Promise<void> {
    if (this.detecting) {
      this.relay?.disableDetection()
    } else {
      await this.relay?.enableDetection()
    }
  }

  private async pick(kind: MediaKind): Promise<void> {
    const uris = await selectCaptures(kind)
    if (uris.length > 0) {
      this.selectedUris = uris
      this.selectedKind = kind
      this.message = '已选择 ' + uris.length + ' 个文件。'
    }
  }

  private async enqueue(): Promise<void> {
    await this.relay?.addSelected(this.selectedUris, this.selectedKind)
    this.selectedUris = []
  }

  private async retry(): Promise<void> {
    this.relay?.retry()
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 7 }) {
          Text('截屏快传')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text('将截图和录屏发送到同一局域网内的电脑。')
            .fontSize(15)
            .fontColor(SUBTLE)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 10 }) {
          Text('配对电脑')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text('电脑地址')
            .fontSize(14)
            .fontColor(SUBTLE)
          TextInput({ text: this.address, placeholder: 'http://192.168.1.20:8765' })
            .type(InputType.Normal)
            .backgroundColor(BACKGROUND)
            .height(48)
            .onChange((value: string): void => { this.address = value })
          Text('配对令牌')
            .fontSize(14)
            .fontColor(SUBTLE)
          TextInput({ text: this.token, placeholder: '输入电脑端显示的令牌' })
            .type(InputType.Password)
            .backgroundColor(BACKGROUND)
            .height(48)
            .onChange((value: string): void => { this.token = value })
          Row({ space: 8 }) {
            Button('保存配对')
              .layoutWeight(1)
              .backgroundColor(ACCENT)
              .enabled(!this.busy && this.relay !== undefined)
              .onClick((): void => { this.action(() => this.saveConfiguration()) })
            Button('测试连接')
              .layoutWeight(1)
              .backgroundColor(BACKGROUND)
              .fontColor(ACCENT)
              .enabled(!this.busy && this.relay !== undefined)
              .onClick((): void => { this.action(() => this.checkConnection()) })
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Color.White)
        .border({ width: 1, color: BORDER })
        .borderRadius(18)
        .padding(16)
        .width('100%')

        Column({ space: 10 }) {
          Text('自动发现')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text(this.detecting ? '已开启。应用打开时检查新文件，返回应用后补传。' :
            '具备华为相册权限的安装包可开启自动发现。')
            .fontSize(14)
            .lineHeight(21)
            .fontColor(SUBTLE)
          Button(this.detecting ? '暂停自动发现' : '授权并开启')
            .backgroundColor(BACKGROUND)
            .fontColor(ACCENT)
            .enabled(this.paired && !this.busy)
            .onClick((): void => { this.action(() => this.changeDetection()) })
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Color.White)
        .border({ width: 1, color: BORDER })
        .borderRadius(18)
        .padding(16)
        .width('100%')

        Column({ space: 10 }) {
          Text('从相册选取')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Row({ space: 8 }) {
            Button('选择截图')
              .layoutWeight(1)
              .backgroundColor(BACKGROUND)
              .fontColor(ACCENT)
              .enabled(this.paired && !this.busy)
              .onClick((): void => { this.action(() => this.pick('screenshot')) })
            Button('选择录屏')
              .layoutWeight(1)
              .backgroundColor(BACKGROUND)
              .fontColor(ACCENT)
              .enabled(this.paired && !this.busy)
              .onClick((): void => { this.action(() => this.pick('screen-recording')) })
          }
          .width('100%')
          if (this.selectedUris.length > 0) {
            Button('发送所选的 ' + this.selectedUris.length + ' 个文件')
              .width('100%')
              .backgroundColor(ACCENT)
              .enabled(this.paired && !this.busy)
              .onClick((): void => { this.action(() => this.enqueue()) })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Color.White)
        .border({ width: 1, color: BORDER })
        .borderRadius(18)
        .padding(16)
        .width('100%')

        Column({ space: 10 }) {
          Text('传输队列')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text(this.pending + ' 待发送  ·  ' + this.sent + ' 已发送  ·  ' + this.failed + ' 失败')
            .fontSize(15)
            .fontColor(INK)
          if (this.otherReceivers > 0) {
            Text(this.otherReceivers + ' 个文件等待原配对地址恢复。')
              .fontSize(14)
              .fontColor(SUBTLE)
          }
          Text(this.message)
            .fontSize(14)
            .lineHeight(21)
            .fontColor(SUBTLE)
          if (this.pending > 0) {
            Button('重试待传文件')
              .backgroundColor(BACKGROUND)
              .fontColor(ACCENT)
              .enabled(this.paired && !this.busy)
              .onClick((): void => { this.action(() => this.retry()) })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Color.White)
        .border({ width: 1, color: BORDER })
        .borderRadius(18)
        .padding(16)
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 28, right: 20, bottom: 24, left: 20 })
      .width('100%')
      .constraintSize({ maxWidth: 620 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BACKGROUND)
    .align(Alignment.Top)
  }
}
