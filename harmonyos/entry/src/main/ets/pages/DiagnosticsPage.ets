import { common } from '@kit.AbilityKit'
import { DiagnosticReports } from '../relay/Diagnostics'
import type { DiagnosticReport } from '../relay/Diagnostics'
import { RelayStorage } from '../relay/Storage'

const INK = '#102438'
const SUBTLE = '#496276'
const ACCENT = '#006658'
const BACKGROUND = '#F2F7F6'

@Entry
@Component
struct DiagnosticsPage {
  @State private reports: DiagnosticReport[] = []
  @State private selected: string[] = []
  @State private failed: string[] = []
  @State private sent: string[] = []
  @State private paired: boolean = false
  @State private sending: boolean = false
  @State private message: string = ''
  private repository: DiagnosticReports | undefined = undefined
  private storage: RelayStorage | undefined = undefined
  private refreshTimer: number = -1

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      this.repository = new DiagnosticReports(context.filesDir)
      this.storage = new RelayStorage(context.filesDir)
      this.refresh()
    } catch (_) {
      this.message = '无法打开应用内的诊断报告。'
    }
  }

  onPageShow(): void {
    this.refresh()
    if (this.refreshTimer === -1) {
      this.refreshTimer = setInterval(() => {
        if (!this.sending) {
          this.refresh()
        }
      }, 5000)
    }
  }

  onPageHide(): void {
    this.stopRefresh()
  }

  aboutToDisappear(): void {
    this.stopRefresh()
  }

  private stopRefresh(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer)
      this.refreshTimer = -1
    }
  }

  private refresh(): void {
    try {
      const reports = this.repository?.list() || []
      const latest = new Set<string>(reports.map((report: DiagnosticReport): string => report.id))
      this.reports = reports
      this.selected = this.selected.filter((id: string): boolean => latest.has(id))
      this.sent = this.sent.filter((id: string): boolean => latest.has(id))
      this.failed = this.failed.filter((id: string): boolean => latest.has(id))
      this.paired = this.storage?.pairing() !== undefined
    } catch (_) {
      this.message = '无法读取诊断报告或电脑配对信息。'
    }
  }

  private setSelected(id: string, value: boolean): void {
    if (value && !this.selected.includes(id)) {
      this.selected = this.selected.concat([id])
    } else if (!value) {
      this.selected = this.selected.filter((selected: string): boolean => selected !== id)
    }
  }

  private async sendSelected(): Promise<void> {
    const repository = this.repository
    if (this.sending || repository === undefined) {
      return
    }
    this.refresh()
    const reports = this.reports.filter((report: DiagnosticReport): boolean => this.selected.includes(report.id))
    if (reports.length === 0) {
      return
    }
    try {
      const pairing = this.storage?.pairing()
      if (pairing === undefined) {
        this.message = '请先在首页配对电脑。'
        return
      }
      this.sending = true
      const uploaded = new Set<string>()
      const failed: string[] = []
      let unauthorized = false
      for (const report of reports) {
        this.message = '正在发送 ' + (uploaded.size + failed.length + 1) + '/' + reports.length
        try {
          const response = await repository.upload(report, pairing)
          if (response.status === 200 || response.status === 201) {
            uploaded.add(report.id)
            continue
          }
          unauthorized = response.status === 401 || response.status === 403
        } catch (_) {
          // Preserve the report and its selection so the user can retry.
        }
        failed.push(report.id)
        if (unauthorized) {
          break
        }
      }
      this.sent = this.sent.filter((id: string): boolean => !uploaded.has(id)).concat(Array.from(uploaded))
      this.failed = this.failed.filter((id: string): boolean => !uploaded.has(id) && !failed.includes(id)).concat(failed)
      this.selected = this.selected.filter((id: string): boolean => !uploaded.has(id))
      const outstanding = reports.length - uploaded.size
      if (unauthorized) {
        this.message = '已发送 ' + uploaded.size + ' 份。电脑拒绝配对令牌，未发送项已保留。'
      } else {
        this.message = outstanding > 0 ? '已发送 ' + uploaded.size + ' 份，' + outstanding + ' 份未发送，可重试。' :
          '已发送 ' + uploaded.size + ' 份诊断日志。'
      }
    } catch (_) {
      this.message = '发送失败，诊断日志和选择已保留。'
    } finally {
      this.sending = false
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Button('返回')
          .backgroundColor(Color.White)
          .fontColor(ACCENT)
          .enabled(!this.sending)
          .onClick((): void => { this.getUIContext().getRouter().back() })
        Text('诊断日志')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Text('近 24 小时本应用的崩溃和无响应记录。选中的报告可发送到配对电脑。')
          .fontSize(15)
          .fontColor(SUBTLE)
        if (!this.paired) {
          Text('请在首页配对电脑后发送。')
            .fontSize(14)
            .fontColor(SUBTLE)
        }
        if (this.message) {
          Text(this.message)
            .fontSize(14)
            .fontColor(SUBTLE)
        }
        if (this.reports.length === 0) {
          Text('暂无系统已送达的诊断日志。')
            .padding(16)
            .width('100%')
            .backgroundColor(Color.White)
            .borderRadius(16)
            .fontSize(15)
            .fontColor(SUBTLE)
        } else {
          Button('发送所选日志（' + this.selected.length + '）')
            .width('100%')
            .backgroundColor(ACCENT)
            .enabled(this.paired && !this.sending && this.selected.length > 0)
            .onClick((): void => { this.sendSelected() })
          ForEach(this.reports, (report: DiagnosticReport) => {
            Row({ space: 12 }) {
              Checkbox({ name: report.id })
                .select(this.selected.includes(report.id))
                .enabled(!this.sending)
                .onChange((value: boolean): void => { this.setSelected(report.id, value) })
              Column({ space: 4 }) {
                Text(report.kind === 'crash' ? '崩溃' : '无响应')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(INK)
                Text(new Date(report.occurredAt).toLocaleString())
                  .fontSize(13)
                  .fontColor(SUBTLE)
                Text('编号 ' + report.id.slice(0, 12))
                  .fontSize(12)
                  .fontColor(SUBTLE)
                if (this.failed.includes(report.id)) {
                  Text('未发送，可重试')
                    .fontSize(12)
                    .fontColor('#963228')
                } else if (this.sent.includes(report.id)) {
                  Text('已发送')
                    .fontSize(12)
                    .fontColor(ACCENT)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Color.White)
            .borderRadius(16)
          }, (report: DiagnosticReport): string => report.id)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 620 })
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 28, right: 20, bottom: 24, left: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BACKGROUND)
    .align(Alignment.Top)
  }
}
