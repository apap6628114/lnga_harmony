export enum FloatingPage {
  NONE = '',
  IMAGE_VIEWER = 'imageViewer',
  PROFILE_CARD = 'profileCard',
  REPLY_DIALOG = 'replyDialog',
  NEW_TOPIC_DIALOG = 'newTopicDialog'
}

/**
 * 全局浮层状态。
 *
 * 说明：确认类弹窗（通用确认、放弃编辑确认）已迁移到官方高级对话框模板，
 * 由调用方各自的 `CustomDialogController` 承载，不再进入本栈——浮层栈只保留
 * 需要全局定位的浮层（图片查看器、资料卡、编辑器半模态）。
 */
@Observed
export class FloatingLayerStoreClass {
  stack: string[] = []

  imageViewerUrls: string[] = []
  imageViewerIndex: number = 0

  profileCardUid: string = ''
  profileCardX: number = 0
  profileCardY: number = 0

  replyDialogTitle: string = '回复'
  replyTargetLou: number = 0
  replyOnSend?: (text: string, isAnony: boolean) => Promise<void>
  editMode: boolean = false
  editInitialContent: string = ''

  /** 发新主题提交回调（push 前赋值；发送失败需 reject，编辑器将保留内容与草稿）。 */
  newTopicOnSend?: (subject: string, content: string, isAnony: boolean) => Promise<void>

  get top(): string {
    return this.stack.length > 0 ? this.stack[this.stack.length - 1] : ''
  }

  get size(): number {
    return this.stack.length
  }

  push(page: string): void {
    const idx = this.stack.indexOf(page)
    if (idx >= 0) {
      const next = [...this.stack]
      next.splice(idx, 1)
      next.push(page)
      this.stack = next
    } else {
      this.stack = [...this.stack, page]
    }
  }

  pop(): boolean {
    if (this.stack.length > 0) {
      this.stack = this.stack.slice(0, -1)
      return true
    }
    return false
  }

  remove(page: string): void {
    this.stack = this.stack.filter(p => p !== page)
  }

  /**
   * 打开资料卡（所有调用点的统一入口）。
   *
   * 两段式压栈的必要性：气泡被**系统**销毁时（应用切后台、横竖屏旋转、折叠状态变化）不会回写
   * 显隐状态，`top` 会残留 `PROFILE_CARD`。此时直接 `push` 只是把同一页移到栈顶——`stack` 虽然
   * 换了新数组，但 `top === PROFILE_CARD` 的布尔结果没变，`bindPopup` 的 `show` 参数不经历
   * `false → true` 跳变，气泡**再也弹不出来**。先移除、下一帧再压栈，保证跳变必然发生。
   * 正常路径（`top` 不是资料卡）不受影响。
   *
   * @param uid - 目标用户 UID
   * @param x - 资料卡左上角的屏幕绝对 x（vp）
   * @param y - 资料卡左上角的屏幕绝对 y（vp）
   */
  openProfileCard(uid: string, x: number, y: number): void {
    const stuck: boolean = this.top === FloatingPage.PROFILE_CARD
    this.profileCardUid = uid
    this.profileCardX = x
    this.profileCardY = y
    if (stuck) {
      this.remove(FloatingPage.PROFILE_CARD)
      setTimeout((): void => {
        this.push(FloatingPage.PROFILE_CARD)
      }, 0)
    } else {
      this.push(FloatingPage.PROFILE_CARD)
    }
  }

  clear(): void {
    this.stack = []
  }

  // Reply close handler (for system back interception)
  private _replyCloseHandler: (() => void) | null = null

  registerReplyCloseHandler(handler: (() => void) | null): void {
    this._replyCloseHandler = handler
  }

  notifyReplyCloseRequested(): void {
    if (this._replyCloseHandler) {
      this._replyCloseHandler()
    }
  }
}

export const floatingLayerStore = new FloatingLayerStoreClass()
