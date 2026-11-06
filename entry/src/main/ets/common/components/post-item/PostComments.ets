import { AppColors } from '../../constants/Constants'
import { Avatar } from '../Avatar'
import { AnonymousName } from '../AnonymousName'
import { getCachedBBNodes } from '../../../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from '../BBCodeContentView'
import { PostInfo } from '../../../model/PostInfo'
import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { appStore } from '../../../store/AppStore'
import { stripCommentReplyHeader } from '../../utils/QuoteInjection'

/**
 * 过滤掉指定类型的 BBCode 节点（递归处理子节点），并清理开头的空文本节点。
 */
function filterBBTags(nodes: BBNode[], skipTypes: BBNodeType[]): BBNode[] {
  const result: BBNode[] = []
  for (const node of nodes) {
    if (skipTypes.indexOf(node.type) >= 0) continue
    if (node.children && node.children.length > 0) {
      const n = new BBNode()
      n.type = node.type
      n.text = node.text
      n.id = node.id
      n.href = node.href
      n.color = node.color
      n.size = node.size
      n.src = node.src
      n.videoSrc = node.videoSrc
      n.title = node.title
      n.emotionCat = node.emotionCat
      n.emotionCode = node.emotionCode
      n.fontFamily = node.fontFamily
      n.align = node.align
      n.colSpan = node.colSpan
      n.rowSpan = node.rowSpan
      n.colWidth = node.colWidth
      n.inheritedFormatTags = node.inheritedFormatTags
      n.children = filterBBTags(node.children, skipTypes)
      result.push(n)
    } else {
      result.push(node)
    }
  }

  // 剔除最前面的纯空白/换行节点
  while (
    result.length > 0 &&
      result[0].type === BBNodeType.TEXT &&
      (!result[0].text || result[0].text.trim() === '')
  ) {
    result.shift()
  }

  if (result.length > 0 && result[0].type === BBNodeType.TEXT && result[0].text) {
    result[0].text = result[0].text.replace(/^[\r\n]+/, '')
  }

  return result
}

/**
 * 帖子评论区子组件。
 */
@Component
export struct PostComments {
  /** 所属帖子信息（@Prop 值拷贝），评论来自 post.comments */
  @Prop post: PostInfo = new PostInfo()
  /** 图片点击回调 */
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  /** 链接点击回调 */
  onLinkClick: (href: string) => void = (_href: string) => {}
  /** 点击评论用户资料回调，传入 uid 与点击位置的屏幕坐标 */
  onProfileClick: (uid: string, screenX: number, screenY: number) => void =
    (_uid: string, _x: number, _y: number) => {}
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0

  /**
   * 判断楼中楼作者是否已被屏蔽。
   *
   * @param comment - 待判断的楼中楼回复
   * @returns 作者是否在实时黑名单中
   */
  private isCommentBlacklisted(comment: PostInfo): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(comment.authorid))
  }

  /**
   * 评论正文节点。
   *
   * 回复头正常剥离后不再显示（评论气泡上方没有树关系，头本身是噪音）。但有两种情况
   * 过滤后什么也不剩，必须回退到未过滤节点，避免空气泡：
   * - 整条评论只有回复头：`stripCommentReplyHeader` 保守回退原文（`POST_BY` 必须保留）；
   * - 评论只剩一个 `[quote]` 块（用户引用别人但自己没写）：引用块就是唯一内容。
   *
   * 不能用「`display === comment.content`」推断回退：列表页历史上会先把评论的
   * Reply-to 头注入成 `[quote]`（已停止注入，但旧调用方/缓存数据仍可能如此），
   * 仅按入参是否原样返回判断会漏掉「只剩 QUOTE」的情形。
   *
   * @param comment - 评论
   * @returns 用于渲染的 BBCode 节点
   */
  private commentNodes(comment: PostInfo): BBNode[] {
    const display: string = stripCommentReplyHeader(comment.content)
    const nodes: BBNode[] = getCachedBBNodes(display)
    const filtered: BBNode[] = filterBBTags(nodes, [BBNodeType.QUOTE, BBNodeType.POST_BY])
    if (this.hasRenderableNode(filtered)) {
      return filtered
    }
    return filterBBTags(nodes, [])
  }

  /**
   * 节点里是否还有可渲染内容（非文本节点，或含非空白文字的文本节点）。
   *
   * @param nodes - 已过滤的节点
   * @returns 至少有一个可见内容时返回 true
   */
  private hasRenderableNode(nodes: BBNode[]): boolean {
    for (let i: number = 0; i < nodes.length; i++) {
      const node: BBNode = nodes[i]
      if (node.type !== BBNodeType.TEXT) {
        return true
      }
      if (node.text.length > 0 && node.text.trim().length > 0) {
        return true
      }
    }
    return false
  }

  build() {
    Column() {
      // 直接渲染全部评论，不再折叠
      ForEach(this.post.comments, (c: PostInfo) => {
        Column() {
          // 用户头像和名字行
          Row() {
            Avatar({ avatar: c.avatar, uid: String(c.authorid), name: c.author, avatarSize: 24 })
              .onClick((event: ClickEvent) => {
                if (c.isanonymous) {
                  appStore.showToast('该用户已匿名')
                  return
                }
                const uid = String(c.authorid)
                if (uid) {
                  this.onProfileClick(uid, event.windowX, event.windowY)
                }
              })

            Column() {
              AnonymousName({ author: c.author, isAnonymous: c.isanonymous, fontSize: 12, normalColor: AppColors.primary, isMuted: c.isMuted })
              if (appStore.settingsStore.getNote(String(c.authorid)).length > 0) {
                Text('(' + appStore.settingsStore.getNote(String(c.authorid)) + ')')
                  .fontSize(10).fontColor(AppColors.warning)
              }
            }
            .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 气泡卡片主体（带向左上方/头像方向指的尖角）
          Row() {
            // 左上角尖角：顶端平齐，顶点向左上方指向头像
            Polygon({ width: 8, height: 8 })
              .points([[0, 0], [8, 0], [8, 8]])
              .fill(AppColors.bgSecondary)

            // 气泡右侧内容框
            Column() {
              if (this.isCommentBlacklisted(c)) {
                Text('该用户已被屏蔽')
                  .fontSize(13)
                  .fontColor(AppColors.textTertiary)
                  .width('100%')
                  .textAlign(TextAlign.Center)
              } else {
                BBCodeContentView({
                  nodes: this.commentNodes(c),
                  onImageClick: this.onImageClick,
                  onLinkClick: this.onLinkClick,
                }).width('100%')
              }
            }
            .layoutWeight(1)
            .padding({ top: 6, bottom: 6, left: 10, right: 10 })
            .backgroundColor(AppColors.bgSecondary)
            .borderRadius({ topRight: 8, bottomLeft: 8, bottomRight: 8 })
          }
          .width('100%')
          .padding({ left: 24 })
          .margin({ top: 2 })
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })
      }, (c: PostInfo) => String(c.pid))
    }
    .width('100%')
    .margin({ top: 12 })
  }
}
