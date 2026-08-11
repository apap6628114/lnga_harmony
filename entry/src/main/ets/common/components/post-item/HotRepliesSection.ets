import { AppColors } from '../../constants/Constants'
import { Avatar } from '../Avatar'
import { AnonymousName } from '../AnonymousName'
import { getCachedBBNodes } from '../../../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from '../BBCodeContentView'
import { PostInfo } from '../../../model/PostInfo'
import { appStore } from '../../../store/AppStore'

/**
 * 热点回复区子组件。
 *
 * 展示宿主楼层（通常为楼主）携带的热点回复列表，每条样式模仿楼中楼评论
 * （PostComments）：作者行（头像/昵称/备注 + 点赞数徽标 + 原楼层号）与
 * 带左上角尖角的圆角气泡（bgSecondary），内容为 BBCode 完整渲染。
 * 作者被黑名单遮蔽时气泡内显示占位文本。
 */
@Component
export struct HotRepliesSection {
  /** 所属帖子信息（@Prop 值拷贝），热点回复来自 post.hotReplies */
  @Prop post: PostInfo = new PostInfo()
  /** 图片点击回调 */
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  /** 链接点击回调 */
  onLinkClick: (href: string) => void = (_href: string) => {}
  /** 点击热点回复作者资料回调，传入 uid 与点击位置的屏幕坐标 */
  onProfileClick: (uid: string, screenX: number, screenY: number) => void =
    (_uid: string, _x: number, _y: number) => {}
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0

  /**
   * 判断热点回复作者是否已被屏蔽。
   *
   * @param reply - 待判断的热点回复
   * @returns 作者是否在实时黑名单中
   */
  private isReplyBlacklisted(reply: PostInfo): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(reply.authorid))
  }

  build() {
    Column() {
      Text('热门回复')
        .fontSize(12)
        .fontColor(AppColors.textSecondary)
        .width('100%')

      ForEach(this.post.hotReplies, (r: PostInfo) => {
        Column() {
          // 作者行：头像 + 昵称/备注 + 点赞数徽标 + 原楼层号
          Row() {
            Avatar({ avatar: r.avatar, uid: String(r.authorid), name: r.author, avatarSize: 24 })
              .onClick((event: ClickEvent) => {
                if (r.isanonymous) {
                  appStore.showToast('该用户已匿名')
                  return
                }
                const uid = String(r.authorid)
                if (uid) {
                  this.onProfileClick(uid, event.windowX, event.windowY)
                }
              })

            Column() {
              AnonymousName({ author: r.author, isAnonymous: r.isanonymous, fontSize: 12, normalColor: AppColors.primary, isMuted: r.isMuted })
              if (appStore.settingsStore.getNote(String(r.authorid)).length > 0) {
                Text('(' + appStore.settingsStore.getNote(String(r.authorid)) + ')')
                  .fontSize(10).fontColor(AppColors.warning)
              }
            }
            .margin({ left: 8 })
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (r.score > 0) {
              Text('+' + String(r.score))
                .fontSize(12)
                .fontColor(AppColors.primary)
                .fontWeight(FontWeight.Medium)
            }

            Text('#' + String(r.lou))
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
              .margin({ left: 6 })
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
              if (this.isReplyBlacklisted(r)) {
                Text('该用户已被屏蔽')
                  .fontSize(13)
                  .fontColor(AppColors.textTertiary)
                  .width('100%')
                  .textAlign(TextAlign.Center)
              } else {
                BBCodeContentView({
                  nodes: getCachedBBNodes(r.content),
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
      }, (r: PostInfo) => String(r.pid))
    }
    .width('100%')
    .margin({ top: 12 })
  }
}
