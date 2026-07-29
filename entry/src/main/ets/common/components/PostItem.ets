import { AppColors } from '../constants/Constants'
import { parseAlterinfoTs, formatTimestampCST } from '../utils/Utils'
import { getCachedBBNodes } from '../../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from './BBCodeContentView'
import { PostInfo } from '../../model/PostInfo'
import { PostItemHeader } from './post-item/PostItemHeader'
import { PostAttachments } from './post-item/PostAttachments'
import { PostVoteBar } from './post-item/PostVoteBar'
import { PostComments } from './post-item/PostComments'
import { appStore } from '../../store/AppStore'

/**
 * 帖子卡片组件（编排层）。
 *
 * 由 4 个独立子组件编排而成：PostItemHeader（顶部）、PostAttachments（附件区）、
 * PostVoteBar（动作栏）、PostComments（评论区）。本组件保留签名折叠区（sigExpanded）
 * 与屏蔽/编辑时间/正文渲染等主体逻辑。所有展开/折叠/菜单状态已下沉对应子组件，
 * 各子组件自持 @State 并在 aboutToReuse 中重置；本组件 aboutToReuse 仅重置 sigExpanded。
 */
@Component
export struct PostItem {
  /** 所属帖子信息（@Prop 值拷贝） */
  @Prop post: PostInfo = new PostInfo()
  /** 是否已点赞 */
  @Prop isVotedUp: boolean = false
  /** 是否已踩 */
  @Prop isVotedDown: boolean = false
  /** 握姿：0=右手布局，1=左手布局 */
  @Prop holdingHand: number = 0
  /** 是否显示签名，订阅 AppStorage */
  @StorageProp('showSignature') showSignature: boolean = true
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0
  /** 签名折叠状态 */
  @State private sigExpanded: boolean = false
  /** 图片点击回调 */
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  /** 链接点击回调 */
  onLinkClick: (href: string) => void = (_href: string) => {}
  /** 视频点击回调 */
  onVideoClick: (url: string) => void = (_url: string) => {}
  /** 点击用户资料回调，传入 uid 与点击位置的屏幕坐标 */
  onProfileClick: (uid: string, screenX: number, screenY: number) => void = (_uid: string, _x: number, _y: number) => {}
  /** 投票回调，value=1 为赞，-1 为踩 */
  onVote: (post: PostInfo, value: number) => void = (_post: PostInfo, _value: number) => {}
  /** 回复回调 */
  onReply: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 评论回调 */
  onComment: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 编辑回调 */
  onEdit: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 分享回调 */
  onShare: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** AI 总结回调 */
  onSummarize: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 朗读回调 */
  onReadAloud: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 是否为主题作者（楼主），传给 PostItemHeader 显示标记 */
  isTopicAuthor: boolean = false
  /** 是否为本人的帖子，传给 PostVoteBar 决定是否显示编辑按钮 */
  isOwnPost: boolean = false

  aboutToReuse(params: Record<string, Object>): void {
    this.sigExpanded = false
  }

  /**
   * 判断当前楼层作者是否已被屏蔽。
   *
   * @returns 作者是否在实时黑名单中
   */
  private isPostBlacklisted(): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(this.post.authorid))
  }

  build() {
    Column() {
        PostItemHeader({
          post: this.post,
          isTopicAuthor: this.isTopicAuthor,
          onProfileClick: this.onProfileClick,
        })

        if (this.isPostBlacklisted()) {
          Text('该用户已被屏蔽').fontSize(14).fontColor(AppColors.textTertiary)
            .margin({ top: 16 }).width('100%').textAlign(TextAlign.Center).padding({ top: 20, bottom: 20 })
        } else {
          Row() {
            Text(this.post.postdate).fontSize(11).fontColor(AppColors.textTertiary)
            if (this.post.alterinfo && this.post.alterinfo.length > 0) {
              Text(this.getEditTimeDisplay()).fontSize(11).fontColor(AppColors.textTertiary)
            }
          }.margin({ top: 12 })

          BBCodeContentView({
            nodes: getCachedBBNodes(this.post.content),
            onImageClick: this.onImageClick,
            onLinkClick: this.onLinkClick,
          }).width('100%').margin({ top: 12 })

          if (this.post.attachs.length > 0) {
            PostAttachments({
              post: this.post,
              onImageClick: this.onImageClick,
            })
          }

          if (this.showSignature && this.post.signature && this.post.signature.length > 0) {
            Column() {
              Row() {
                Text('签名')
                  .fontSize(10).fontColor(AppColors.textTertiary)
                Image($r('app.media.icon_chevron_down'))
                  .width(12).height(12).fillColor(AppColors.textTertiary)
                  .rotate({ angle: this.sigExpanded ? 180 : 0 })
                  .margin({ left: 2 })
              }
              .margin({ bottom: 4 })
              .onClick(() => { this.sigExpanded = !this.sigExpanded })

              if (this.sigExpanded) {
                Column() {
                  BBCodeContentView({
                    nodes: getCachedBBNodes(this.post.signature),
                    onImageClick: this.onImageClick,
                    onLinkClick: this.onLinkClick,
                    hideFailedImages: true,
                  })
                }
                .width('100%')
              } else {
                Text(this.getSignaturePreview())
                  .fontSize(12)
                  .fontColor(AppColors.textSecondary)
                  .lineHeight(20)
                  .maxLines(4)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 12 })
            .padding({ left: 10, top: 4, bottom: 4 })
            .border({ width: { left: 2 }, color: AppColors.separator })
          }

          PostVoteBar({
            post: this.post,
            isVotedUp: this.isVotedUp,
            isVotedDown: this.isVotedDown,
            holdingHand: this.holdingHand,
            isOwnPost: this.isOwnPost,
            onVote: this.onVote,
            onReply: this.onReply,
            onEdit: this.onEdit,
            onShare: this.onShare,
            onSummarize: this.onSummarize,
            onReadAloud: this.onReadAloud,
          })
        }

        if (this.post.comments.length > 0) {
          PostComments({
            post: this.post,
            onImageClick: this.onImageClick,
            onLinkClick: this.onLinkClick,
            onProfileClick: this.onProfileClick,
          })
        }
      }
      .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 }).alignItems(HorizontalAlign.Start)
  }

  private getEditTimeDisplay(): string {
    if (!this.post.alterinfo || this.post.alterinfo.length === 0) return ''
    const et: number | null = parseAlterinfoTs(this.post.alterinfo)
    if (et === null) return ''
    return ' [在' + formatTimestampCST(et) + '修改]'
  }

  private getSignaturePreview(): string {
    let s: string = this.post.signature || ''
    s = s.replace(/\[quote\][\s\S]*?\[\/quote\]/gi, '')
    s = s.replace(/\[\/?(?:pid|uid|tid|b|i|u|del|h|url|color|size|font|collapse|code|img|flash|audio|list|item|align|style|table|tr|td|sub|sup)\d*[^\]]*\]/gi, '')
    s = s.replace(/\[s:\w+:\w+\]/g, '')
    s = s.replace(/<[^>]+>/g, '')
    s = s.replace(/https?:\/\/\S+/g, '')
    s = s.replace(/\s+/g, ' ').trim()
    if (s.length > 160) {
      return s.substring(0, 160) + '...'
    }
    return s
  }
}
