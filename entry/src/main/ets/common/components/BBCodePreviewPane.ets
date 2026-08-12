/**
 * BBCode 草稿预览面板。
 *
 * 供发帖/回复编辑器在“预览”态复用：直接调用 parseBBCode 解析草稿源文
 * （刻意绕过 BBCodeCache 的 LRU 缓存，避免高频草稿文本挤占帖子正文缓存），
 * 并以与帖子正文相同的 BBCodeContentView 渲染，保证“预览即发布效果”。
 *
 * 草稿中的图片在上传成功但发布前不对外可见（服务端在发帖提交后才将附件
 * 落位到公开 CDN，此前访问其 URL 只得到 404 占位图），因此预览期间移除
 * 图片节点并以提示文案告知。
 */

import { common } from '@kit.AbilityKit'
import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { parseBBCode } from '../../parser/bbcode/parser'
import { BBCodeContentView } from './BBCodeContentView'
import { handleForumLink } from '../utils/LinkUtils'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'

/** 用沉浸光感材质承载 BBCode 草稿的只读预览。 */
@Component
export struct BBCodePreviewPane {
  /** 待预览的 BBCode 源文（含引用前缀的最终发送串）。 */
  content: string = ''

  /** 预览视口高度（vp），与编辑态 TextArea 高度对齐，避免切换时布局跳变。 */
  viewportHeight: number = 240

  /** 面板挂载时解析出的节点树（已移除未发布图片）；预览期间源文不可变，无需响应式更新。 */
  private nodes: BBNode[] = []

  /** 预览中被跳过的图片数量，用于提示“发布后可见”。 */
  private skippedImageCount: number = 0

  /** 挂载时解析源文并移除未发布图片节点。 */
  aboutToAppear(): void {
    this.nodes = parseBBCode(this.content)
    this.skippedImageCount = this.removeImageNodes(this.nodes)
  }

  /**
   * 递归移除节点树中的图片节点。
   *
   * 上传的附件在发布提交前不对外可见（公开 CDN 上尚无该文件），
   * 预览期间跳过渲染，避免 Image 组件加载 404 后显示 1px 占位图。
   *
   * @param nodes - 待处理的节点数组
   * @returns 被移除的图片节点数量
   */
  private removeImageNodes(nodes: BBNode[]): number {
    let removed: number = 0
    for (let i: number = nodes.length - 1; i >= 0; i--) {
      const node: BBNode = nodes[i]
      if (node.type === BBNodeType.IMAGE) {
        nodes.splice(i, 1)
        removed++
      } else if (node.children.length > 0) {
        removed += this.removeImageNodes(node.children)
      }
    }
    return removed
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
      Column() {
        if (this.skippedImageCount > 0) {
          Text('包含 ' + this.skippedImageCount.toString() + ' 张图片，发布后可见')
            .fontSize(12)
            .fontColor(AppColors.textTertiary)
            .width('100%')
            .margin({ bottom: 8 })
        }
        if (this.nodes.length > 0) {
          BBCodeContentView({
            nodes: this.nodes,
            onLinkClick: (href: string): void => {
              this.handlePreviewLink(href)
            }
          })
        } else if (this.skippedImageCount === 0) {
          Text('正文为空，无可预览内容')
            .fontSize(13)
            .fontColor(AppColors.textTertiary)
            .margin({ top: 12 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
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
