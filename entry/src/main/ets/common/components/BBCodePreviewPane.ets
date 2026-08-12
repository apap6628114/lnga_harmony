/**
 * BBCode 草稿预览面板。
 *
 * 供发帖/回复编辑器在“预览”态复用：直接调用 parseBBCode 解析草稿源文
 * （刻意绕过 BBCodeCache 的 LRU 缓存，避免高频草稿文本挤占帖子正文缓存），
 * 并以与帖子正文相同的 BBCodeContentView 渲染，保证“预览即发布效果”。
 */

import { common } from '@kit.AbilityKit'
import { BBNode } from '../../model/BBCodeNode'
import { parseBBCode } from '../../parser/bbcode/parser'
import { BBCodeContentView } from './BBCodeContentView'
import { openImageViewer, handleForumLink } from '../utils/LinkUtils'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'

/** 用沉浸光感材质承载 BBCode 草稿的只读预览。 */
@Component
export struct BBCodePreviewPane {
  /** 待预览的 BBCode 源文（含引用前缀的最终发送串）。 */
  content: string = ''

  /** 预览视口高度（vp），与编辑态 TextArea 高度对齐，避免切换时布局跳变。 */
  viewportHeight: number = 240

  /** 面板挂载时解析出的节点树；预览期间源文不可变，无需响应式更新。 */
  private nodes: BBNode[] = []

  /** 挂载时解析源文。 */
  aboutToAppear(): void {
    this.nodes = parseBBCode(this.content)
  }

  /**
   * 处理预览内链接点击，与帖子正文的链接行为保持一致。
   *
   * @param href - 被点击链接地址
   */
  private handlePreviewLink(href: string): void {
    const hostCtx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext
    if (hostCtx !== undefined) {
      handleForumLink(href, hostCtx)
    }
  }

  /** 构建预览面板。 */
  build() {
    Scroll() {
      if (this.nodes.length === 0) {
        Text('正文为空，无可预览内容')
          .fontSize(13)
          .fontColor(AppColors.textTertiary)
          .margin({ top: 12 })
      } else {
        BBCodeContentView({
          nodes: this.nodes,
          onImageClick: (urls: string[], index: number): void => {
            openImageViewer(urls, index)
          },
          onLinkClick: (href: string): void => {
            this.handlePreviewLink(href)
          }
        })
      }
    }
    .width('100%')
    .height(this.viewportHeight)
    .padding(14)
    .borderRadius(16)
    .backgroundColor(Color.Transparent)
    .border({ width: 0.5, color: AppColors.separator })
    .systemMaterial(UIMaterialManager.inputMaterial)
    .align(Alignment.TopStart)
  }
}
