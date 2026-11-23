import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { DownloadReceiver, exportReceived } from '../relay/Download'
import type { ReceivedFile } from '../relay/Download'
import { selectCaptures, selectFiles } from '../relay/Media'
import type { MediaKind } from '../relay/Media'
import { scanDownloadCode } from '../relay/Pairing'
import { Relay } from '../relay/Relay'
import type { RelayStatus } from '../relay/Relay'

const INK = '#14234A'
const SUBTLE = '#526282'
const ACCENT = '#2558DD'
const BACKGROUND = '#F3F6FC'
const SURFACE_BLUE = '#EDF2FF'
const BORDER = '#DFE7F4'

@Entry
@Component
struct Index {
  @State private address: string = ''
  @State private token: string = ''
  @State private paired: boolean = false
  @State private pairedAddress: string = ''
  @State private manualPairing: boolean = false
  @State private busy: boolean = false
  @State private pending: number = 0
  @State private sent: number = 0
  @State private failed: number = 0
  @State private otherReceivers: number = 0
  @State private selectedUris: string[] = []
  @State private selectionMessage: string = ''
  @State private message: string = ''
  @State private pairingMessage: string = ''
  @State private downloadMessage: string = ''
  @State private receivedDirectory: string = ''
  @State private receivedFiles: ReceivedFile[] = []
  private selectedKind: MediaKind = 'photo'
  private relay: Relay | undefined = undefined
  private receiver: DownloadReceiver | undefined = undefined
  private context: common.UIAbilityContext | undefined = undefined

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    this.context = context
    try {
      this.relay = new Relay(context, (status: RelayStatus): void => this.applyStatus(status))
      const status = this.relay.status()
      this.address = status.endpoint
      this.token = status.token
      this.applyStatus(status)
    } catch (_) {
      this.message = '无法打开本地传输记录。请检查设备剩余空间后重新打开应用。'
    }
    try {
      this.receiver = new DownloadReceiver(context.filesDir)
      this.receivedDirectory = this.receiver.directory
      this.receivedFiles = this.receiver.list()
    } catch (_) {
      this.downloadMessage = '无法打开接收目录。请检查设备存储空间。'
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
    this.pairedAddress = status.endpoint
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
    try {
      this.relay?.saveSettings(this.address, this.token)
      this.manualPairing = false
      this.pairingMessage = '已保存配对。'
    } catch (error) {
      this.pairingMessage = (error as BusinessError).message || '无法保存配对。'
    }
  }

  private async scanPairing(): Promise<void> {
    const relay = this.relay
    if (relay === undefined) {
      return
    }
    this.pairingMessage = '正在扫码配对…'
    try {
      if (!(await relay.pairByScan())) {
        this.pairingMessage = '已取消扫码。'
        return
      }
      const status = relay.status()
      this.address = status.endpoint
      this.token = status.token
      this.manualPairing = false
      this.pairingMessage = '扫码配对成功。'
    } catch (error) {
      this.pairingMessage = (error as BusinessError).message || '扫码配对失败，请重试。'
    }
  }

  private async checkConnection(): Promise<void> {
    try {
      const target = this.manualPairing ? this.address : this.pairedAddress
      const available = await this.relay?.checkConnection(target)
      this.pairingMessage = available ? '电脑可以连接。' : '电脑没有返回可用状态。'
    } catch (_) {
      this.pairingMessage = '连接失败。请核对地址，并确认两台设备在同一局域网。'
    }
  }

  private async scanDownload(): Promise<void> {
    const context = this.context
    const receiver = this.receiver
    if (context === undefined || receiver === undefined) {
      return
    }
    this.downloadMessage = '正在扫描文件二维码…'
    try {
      const share = await scanDownloadCode(context)
      if (share === undefined) {
        this.downloadMessage = '已取消扫码。'
        return
      }
      this.downloadMessage = '正在连接电脑…'
      const file = await receiver.receive(share, (name: string, received: number, total: number): void => {
        const percent = total > 0 ? Math.floor(received / total * 100) : 0
        this.downloadMessage = '正在接收 ' + name + ' · ' + percent + '%'
      })
      this.receivedFiles = receiver.list()
      this.downloadMessage = '已接收 ' + file.name
    } catch (error) {
      this.downloadMessage = (error as BusinessError).message || '接收失败，请重新扫码。'
    }
  }

  private async exportDownload(file: ReceivedFile): Promise<void> {
    const context = this.context
    if (context === undefined) {
      return
    }
    try {
      if (await exportReceived(context, file)) {
        this.downloadMessage = '已导出 ' + file.name
      }
    } catch (_) {
      this.downloadMessage = '导出失败，请选择可写入的文件夹。'
    }
  }

  private async pick(kind: MediaKind): Promise<void> {
    const context = this.context
    if (context === undefined) {
      return
    }
    try {
      const uris = kind === 'file' ? await selectFiles(context) : await selectCaptures(kind)
      if (uris.length > 0) {
        this.selectedUris = uris
        this.selectedKind = kind
        this.selectionMessage = ''
      }
    } catch (_) {
      this.selectionMessage = '未能取得所选文件，请重新选择。'
    }
  }

  private async enqueue(): Promise<void> {
    try {
      const result = await this.relay?.addSelected(this.selectedUris, this.selectedKind)
      if (result !== undefined) {
        this.selectedUris = result.remaining
        this.selectionMessage = result.message
      }
    } catch (error) {
      this.selectionMessage = (error as BusinessError).message || '暂时无法发送，所选文件已保留。'
    }
  }

  private async retry(): Promise<void> {
    this.relay?.retry()
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 8 }) {
          Text('截屏快传')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
            .layoutWeight(1)
          Text(this.paired ? '已配对' : '未配对')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.paired ? ACCENT : SUBTLE)
            .backgroundColor(this.paired ? SURFACE_BLUE : Color.White)
            .borderRadius(20)
            .padding({ top: 6, right: 11, bottom: 6, left: 11 })
        }
        .width('100%')

        Column({ space: 10 }) {
          Button('选择图片上传')
            .width('100%')
            .height(54)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .backgroundColor(ACCENT)
            .borderRadius(14)
            .enabled(this.paired && !this.busy)
            .onClick((): void => { this.action(() => this.pick('photo')) })
          Row({ space: 8 }) {
            Button('选择视频上传')
              .layoutWeight(1)
              .height(44)
              .fontColor(ACCENT)
              .backgroundColor(SURFACE_BLUE)
              .borderRadius(12)
              .enabled(this.paired && !this.busy)
              .onClick((): void => { this.action(() => this.pick('video')) })
            Button('选择文件上传')
              .layoutWeight(1)
              .height(44)
              .fontColor(ACCENT)
              .backgroundColor(SURFACE_BLUE)
              .borderRadius(12)
              .enabled(this.paired && !this.busy)
              .onClick((): void => { this.action(() => this.pick('file')) })
          }
          .width('100%')
          if (this.selectedUris.length > 0) {
            Button('发送所选的 ' + this.selectedUris.length + ' 个文件')
              .width('100%')
              .height(44)
              .fontColor(ACCENT)
              .backgroundColor(SURFACE_BLUE)
              .borderRadius(12)
              .enabled(this.paired && !this.busy)
              .onClick((): void => { this.action(() => this.enqueue()) })
          }
          if (this.selectionMessage) {
            Text(this.selectionMessage)
              .fontSize(14)
              .lineHeight(21)
              .fontColor(SUBTLE)
          }
          Button('扫码接收文件')
            .width('100%')
            .height(44)
            .fontColor(ACCENT)
            .backgroundColor(Color.White)
            .border({ width: 1, color: BORDER })
            .borderRadius(12)
            .enabled(!this.busy && this.receiver !== undefined)
            .onClick((): void => { this.action(() => this.scanDownload()) })
          if (this.downloadMessage) {
            Text(this.downloadMessage)
              .fontSize(14)
              .lineHeight(21)
              .fontColor(SUBTLE)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Color.White)
        .border({ width: 1, color: BORDER })
        .borderRadius(20)
        .padding(16)
        .width('100%')

        Column({ space: 12 }) {
          Text('配对电脑')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          if (this.paired) {
            Text(this.pairedAddress)
              .fontSize(14)
              .fontColor(SUBTLE)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Row({ space: 8 }) {
            Button('扫码配对')
              .layoutWeight(1)
              .height(44)
              .fontColor(ACCENT)
              .backgroundColor(SURFACE_BLUE)
              .borderRadius(12)
              .enabled(!this.busy && this.relay !== undefined)
              .onClick((): void => { this.action(() => this.scanPairing()) })
            Button(this.manualPairing ? '收起手动配对' : '手动配对')
              .layoutWeight(1)
              .height(44)
              .fontColor(ACCENT)
              .backgroundColor(Color.White)
              .border({ width: 1, color: BORDER })
              .borderRadius(12)
              .enabled(!this.busy && this.relay !== undefined)
              .onClick((): void => { this.manualPairing = !this.manualPairing })
          }
          .width('100%')
          if (this.manualPairing) {
            Text('电脑地址')
              .fontSize(14)
              .fontColor(SUBTLE)
            TextInput({ text: this.address, placeholder: 'http://192.168.1.20:8765' })
              .type(InputType.Normal)
              .backgroundColor(BACKGROUND)
              .height(46)
              .onChange((value: string): void => { this.address = value })
            Text('配对令牌')
              .fontSize(14)
              .fontColor(SUBTLE)
            TextInput({ text: this.token, placeholder: '输入电脑端显示的令牌' })
              .type(InputType.Password)
              .backgroundColor(BACKGROUND)
              .height(46)
              .onChange((value: string): void => { this.token = value })
            Row({ space: 8 }) {
              Button('保存配对')
                .layoutWeight(1)
                .height(44)
                .backgroundColor(ACCENT)
                .borderRadius(12)
                .enabled(!this.busy && this.relay !== undefined)
                .onClick((): void => { this.action(() => this.saveConfiguration()) })
              Button('测试连接')
                .layoutWeight(1)
                .height(44)
                .fontColor(ACCENT)
                .backgroundColor(SURFACE_BLUE)
                .borderRadius(12)
                .enabled(!this.busy && this.relay !== undefined)
                .onClick((): void => { this.action(() => this.checkConnection()) })
            }
            .width('100%')
          } else if (this.paired) {
            Button('测试连接')
              .fontColor(ACCENT)
              .backgroundColor(Color.White)
              .enabled(!this.busy)
              .onClick((): void => { this.action(() => this.checkConnection()) })
          }
          if (this.pairingMessage) {
            Text(this.pairingMessage)
              .fontSize(14)
              .lineHeight(21)
              .fontColor(SUBTLE)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Color.White)
        .border({ width: 1, color: BORDER })
        .borderRadius(20)
        .padding(16)
        .width('100%')

        if (this.receivedFiles.length > 0) {
          Column({ space: 10 }) {
            Text('已接收文件')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK)
            Text(this.receivedDirectory)
              .fontSize(12)
              .fontColor(SUBTLE)
            ForEach(this.receivedFiles, (file: ReceivedFile) => {
              Row({ space: 8 }) {
                Text(file.name)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontSize(14)
                  .fontColor(INK)
                Button('导出')
                  .backgroundColor(SURFACE_BLUE)
                  .fontColor(ACCENT)
                  .enabled(!this.busy)
                  .onClick((): void => { this.action(() => this.exportDownload(file)) })
              }
              .width('100%')
            }, (file: ReceivedFile): string => file.path)
          }
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Color.White)
          .border({ width: 1, color: BORDER })
          .borderRadius(20)
          .padding(16)
          .width('100%')
        }

        if (this.pending + this.sent + this.failed + this.otherReceivers > 0 || this.message) {
          Column({ space: 10 }) {
            Text('传输队列')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK)
            Text(this.pending + ' 待发送  ·  ' + this.sent + ' 已发送  ·  ' + this.failed + ' 失败')
              .fontSize(14)
              .fontColor(INK)
            if (this.otherReceivers > 0) {
              Text(this.otherReceivers + ' 个文件等待原配对地址恢复。')
                .fontSize(14)
                .fontColor(SUBTLE)
            }
            if (this.message) {
              Text(this.message)
                .fontSize(14)
                .lineHeight(21)
                .fontColor(SUBTLE)
            }
            if (this.pending > 0) {
              Button('重试待传文件')
                .backgroundColor(SURFACE_BLUE)
                .fontColor(ACCENT)
                .enabled(this.paired && !this.busy)
                .onClick((): void => { this.action(() => this.retry()) })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Color.White)
          .border({ width: 1, color: BORDER })
          .borderRadius(20)
          .padding(16)
          .width('100%')
        }

        Button('诊断日志')
          .fontColor(SUBTLE)
          .backgroundColor(Color.White)
          .border({ width: 1, color: BORDER })
          .enabled(!this.busy)
          .onClick((): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/DiagnosticsPage' }) })
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 28, right: 18, bottom: 24, left: 18 })
      .width('100%')
      .constraintSize({ maxWidth: 620 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BACKGROUND)
    .align(Alignment.Top)
  }
}
