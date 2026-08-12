export enum FloatingPage {
  NONE = '',
  IMAGE_VIEWER = 'imageViewer',
  PROFILE_CARD = 'profileCard',
  REPLY_DIALOG = 'replyDialog',
  NEW_TOPIC_DIALOG = 'newTopicDialog',
  CONFIRM_DIALOG = 'confirmDialog'
}

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

  confirmTitle: string = ''
  confirmMessage: string = ''
  confirmLabel: string = '确定'
  confirmDestructive: boolean = false
  confirmOnConfirm?: () => void

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

  // Confirm dialog (simplified)
  replyConfirmActive: boolean = false

  showReplyConfirm(): void {
    this.replyConfirmActive = true
  }

  hideReplyConfirm(): void {
    this.replyConfirmActive = false
  }

  /**
   * 放弃当前编辑器内容。
   *
   * 弹出栈顶编辑器浮层（回复或发新主题）并清空关闭处理器；
   * 仅由"放弃编辑"确认弹窗调用，此时栈顶必为编辑器浮层。
   */
  confirmAbandon(): void {
    this.registerReplyCloseHandler(null)
    // 放弃当前编辑器浮层（回复或发新主题），从栈顶弹出
    this.pop()
    this.replyConfirmActive = false
  }

  showConfirm(title: string, message: string, confirmLabel: string, destructive: boolean,
    onConfirm: () => void): void {
    this.confirmTitle = title
    this.confirmMessage = message
    this.confirmLabel = confirmLabel
    this.confirmDestructive = destructive
    this.confirmOnConfirm = onConfirm
    this.push(FloatingPage.CONFIRM_DIALOG)
  }

  hideConfirm(): void {
    this.remove(FloatingPage.CONFIRM_DIALOG)
  }
}

export const floatingLayerStore = new FloatingLayerStoreClass()
