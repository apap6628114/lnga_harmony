import { AppColors } from '../../constants/Constants'
import { Avatar } from '../Avatar'
import { AnonymousName } from '../AnonymousName'
import { getCachedBBNodes } from '../../../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from '../BBCodeContentView'
import { PostInfo } from '../../../model/PostInfo'
import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { appStore } from '../../../store/AppStore'

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
      n.title = node.title
      n.emotionCat = node.emotionCat
      n.emotionCode = node.emotionCode
      n.fontFamily = node.fontFamily
      n.align = node.align
      n.colSpan = node.colSpan
      n.rowSpan = node.rowSpan
      n.colWidth = node.colWidth
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
 * 剥离回复头（如 [b]Reply to ... [/b]）
 */
function stripPostByHeader(content: string): string {
  if (!content) return ''
  return content
    .replace(/^\[b\]Reply\s+to[\s\S]*?\[\/b\]\s*/i, '')
    .replace(/^[\r\n\s]+/, '')
    .trim()
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
              AnonymousName({ author: c.author, isAnonymous: c.isanonymous, fontSize: 12, normalColor: AppColors.primary })
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
                  nodes: filterBBTags(
                    getCachedBBNodes(stripPostByHeader(c.content)),
                    [BBNodeType.QUOTE, BBNodeType.POST_BY]
                  ),
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
