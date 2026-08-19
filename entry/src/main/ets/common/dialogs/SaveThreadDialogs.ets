/**
 * 保存帖子对话框：选择保存的页范围（1~x 页）。
 *
 * 打开时先拉取第一页确认帖子有效性并取得总页数；帖子无效（被删除/过期）
 * 或拉取失败时显示错误并禁止保存。确认后由调用方关闭对话框并启动
 * SavedThreadService 后台保存（进度由全局指示组件展示）。
 */

import { getThread } from '../../service/api/ThreadApi'
import { appStore } from '../../store/AppStore'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'

@CustomDialog
export struct SaveThreadDialog {
  controller: CustomDialogController
  /** NGA 主题 ID。 */
  @Prop tid: string = ''
  /** 调用方提供的主题标题（加载失败时的兜底展示）。 */
  @Prop initialSubject: string = ''
  /** 是否正在拉取帖子信息。 */
  @State loading: boolean = true
  /** 拉取失败原因（空串表示成功）。 */
  @State loadError: string = ''
  /** 主题标题。 */
  @State subject: string = ''
  /** 服务端总页数。 */
  @State totalPages: number = 0
  /** 起始页输入。 */
  @State startText: string = '1'
  /** 结束页输入。 */
  @State endText: string = ''
  /** 确认保存回调（页范围已校验）。 */
  onSave?: (tid: string, startPage: number, endPage: number) => void

  aboutToAppear(): void {
    this.fetchThreadInfo()
  }

  /**
   * 拉取第一页：确认帖子有效并获取总页数/标题。
   */
  private async fetchThreadInfo(): Promise<void> {
    this.loading = true
    this.loadError = ''
    try {
      const result = await getThread(appStore.auth.token, this.tid, '', '', '1')
      if (!result.ok || result.error.length > 0) {
        this.loadError = result.error || '无法加载该帖子'
      } else if (result.posts.length === 0) {
        this.loadError = '帖子不存在或已被删除'
      } else {
        if (result.threadInfo && result.threadInfo.subject.length > 0) {
          this.subject = result.threadInfo.subject
        } else {
          this.subject = result.posts[0].subject || this.initialSubject
        }
        this.totalPages = Math.max(1, result.pagination.totalPages)
        this.endText = String(this.totalPages)
      }
    } catch (e) {
      this.loadError = '无法加载该帖子'
    } finally {
      this.loading = false
    }
  }

  /**
   * 起始页输入是否合法。
   */
  private parseStart(): number {
    const raw: string = this.startText.trim()
    const n: number = Number(raw)
    if (raw.length === 0 || isNaN(n) || n < 1) {
      return -1
    }
    return Math.floor(n)
  }

  /**
   * 结束页输入是否合法。
   */
  private parseEnd(): number {
    const raw: string = this.endText.trim()
    const n: number = Number(raw)
    if (raw.length === 0 || isNaN(n) || n < 1) {
      return -1
    }
    return Math.floor(n)
  }

  /**
   * 是否可以提交保存（加载完成、无错误、页范围合法）。
   */
  private canSave(): boolean {
    if (this.loading || this.loadError.length > 0 || this.totalPages <= 0) {
      return false
    }
    const start: number = this.parseStart()
    const end: number = this.parseEnd()
    return start >= 1 && end >= start && end <= this.totalPages
  }

  /**
   * 当前选择的保存页数；起始/结束页输入非法或结束页超出总页数时返回 0。
   */
  private pageCount(): number {
    const start: number = this.parseStart()
    const end: number = this.parseEnd()
    if (start < 1 || end < start || end > this.totalPages) {
      return 0
    }
    return end - start + 1
  }

  build() {
    Column() {
      Text('保存帖子')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
        .margin({ top: 20, bottom: 4 })
        .alignSelf(ItemAlign.Center)

      if (this.loading) {
        Row({ space: 10 }) {
          LoadingProgress().width(22).height(22).color(AppColors.primary)
          Text('正在确认帖子信息…').fontSize(13).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        }
        .margin({ top: 24, bottom: 28 })
      } else if (this.loadError.length > 0) {
        Text(this.loadError)
          .fontSize(13).fontColor(AppColors.destructive)
          .margin({ top: 16, bottom: 8 })
          .alignSelf(ItemAlign.Center)
        Text('该帖子可能已被删除或已过期，无法保存。')
          .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ bottom: 20 })
          .alignSelf(ItemAlign.Center)
      } else {
        Text(this.subject)
          .fontSize(14).fontColor(AppColors.textPrimary).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8, bottom: 2 })
          .padding({ left: 4, right: 4 })
          .alignSelf(ItemAlign.Start)

        Text('共 ' + String(this.totalPages) + ' 页，请选择要保存的页范围')
          .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ bottom: 14 })
          .alignSelf(ItemAlign.Start)

        Row({ space: 10 }) {
          Column() {
            Text('起始页').fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ bottom: 6 }).alignSelf(ItemAlign.Start)
            TextInput({ text: this.startText, placeholder: '1' })
              .type(InputType.Number).height(40).fontSize(15).borderRadius(10)
              .width('100%')
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .backgroundColor(Color.Transparent)
              .systemMaterial(UIMaterialManager.inputMaterial)
              .onChange((value: string) => { this.startText = value })
          }
          .layoutWeight(1)

          Column() {
            Text('结束页').fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ bottom: 6 }).alignSelf(ItemAlign.Start)
            TextInput({ text: this.endText, placeholder: String(this.totalPages) })
              .type(InputType.Number).height(40).fontSize(15).borderRadius(10)
              .width('100%')
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .backgroundColor(Color.Transparent)
              .systemMaterial(UIMaterialManager.inputMaterial)
              .onChange((value: string) => { this.endText = value })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        if (this.totalPages > 1) {
          Text('将保存 ' + String(this.pageCount()) + ' 页内容')
            .fontSize(12).fontColor(AppColors.warning)
            .margin({ top: 8 })
            .alignSelf(ItemAlign.Start)
          if (this.pageCount() > 50) {
            Text('页数较多，预计耗时较长，保存中可随时取消')
              .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ top: 4 })
              .alignSelf(ItemAlign.Start)
          }
        }
      }

      Divider().color(AppColors.separator).margin({ top: 14 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary).fontSize(16)
          .onClick(() => { this.controller.close() })

        Button('保存')
          .layoutWeight(1).height(44).margin({ left: 12 })
          .backgroundColor(AppColors.primary)
          .fontColor(AppColors.white)
          .fontWeight(FontWeight.Bold).fontSize(16)
          .opacity(this.canSave() ? 1 : 0.45)
          .enabled(this.canSave())
          .onClick(() => {
            const start: number = this.parseStart()
            const end: number = this.parseEnd()
            if (start >= 1 && end >= start && end <= this.totalPages) {
              if (this.onSave) this.onSave(this.tid, start, end)
              this.controller.close()
            }
          })
      }
    }
    // 显式固定对话框宽度（customStyle 模式下内容区默认占满屏幕宽，
    // 若无固定宽度，输入区的 width('100%') 会撑满整个屏幕）
    .width(300)
    .constraintSize({ maxWidth: 340 })
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(Color.Transparent)
    .borderRadius(14)
    .systemMaterial(UIMaterialManager.surfaceMaterial)
  }
}
