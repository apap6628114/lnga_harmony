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
