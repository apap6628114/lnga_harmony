import { AppColors } from '../constants/Constants'
import { parseAlterinfoTs, formatTimestampCST } from '../utils/Utils'
import { resolveFloorSubject } from '../utils/ThreadTreeBuilder'
import { getCachedBBNodes } from '../../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from './BBCodeContentView'
import { PostInfo } from '../../model/PostInfo'
import { VoteResult } from '../../model/NgaApiResults'
import { PostItemHeader } from './post-item/PostItemHeader'
import { PostAttachments } from './post-item/PostAttachments'
import { PostVoteBar } from './post-item/PostVoteBar'
import { PostPoll } from './post-item/PostPoll'
import { PostComments } from './post-item/PostComments'
import { HotRepliesSection } from './post-item/HotRepliesSection'
import { appStore } from '../../store/AppStore'

/**
 * 帖子卡片组件（编排层）。
 *
 * 由 5 个独立子组件编排而成：PostItemHeader（顶部）、PostAttachments（附件区）、
 * PostVoteBar（动作栏）、PostComments（评论区）、HotRepliesSection（热点回复区）。
 * 本组件保留签名折叠区（sigExpanded）与屏蔽/编辑时间/正文渲染等主体逻辑。
 * 所有展开/折叠/菜单状态已下沉对应子组件，各子组件自持 @State 并在 aboutToReuse
 * 中重置；本组件 aboutToReuse 仅重置 sigExpanded。
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
  /** 投票回调，value=1 为赞，-1 为踩；返回服务端最终状态供动作栏局部刷新。 */
  onVote: (post: PostInfo, value: number) => Promise<VoteResult> = async (_post: PostInfo, _value: number): Promise<VoteResult> => {
    const result: VoteResult = new VoteResult()
    result.error = '投票回调未设置'
    return result
  }
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
  /**
   * 正文显示内容覆盖（树阅读模式传入「剥离引用区后的正文」）。
   *
   * 空串表示不覆盖、照常渲染 `post.content`（自然列表模式走这条路径，行为不变）。
   * 引用区已由树的两层关系 + 「回复 @作者 →」表达，树节点正文不再重复显示；但整层只有
   * 引用区时会回退为原文（保守剥离），所以这里收到的仍可能是带引用头的正文。
   *
   * 必须是 `@Prop`：树页刷新后行键值可能不变（pid + rev 相同），LazyForEach 复用
   * 组件实例时只有 `@Prop` 会随新参数更新，普通字段会保留旧值导致正文不刷新。
   */
  @Prop displayContent: string = ''
  /** 是否渲染正文块（树模式剥离引用区后无正文时传 false，避免留下空行）。 */
  @Prop showContent: boolean = true

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
            Text(this.post.postdatetimestamp > 0 ? formatTimestampCST(this.post.postdatetimestamp) : this.post.postdate).fontSize(11).fontColor(AppColors.textTertiary)
            if (this.post.alterinfo && this.post.alterinfo.length > 0) {
              Text(this.getEditTimeDisplay()).fontSize(11).fontColor(AppColors.textTertiary)
            }
          }.margin({ top: 12 })

          if (this.hasPostSubject()) {
            Text(this.resolveSubjectText())
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColors.textPrimary)
              .lineHeight(21)
              .width('100%')
              .margin({ top: 10 })
          }

          if (this.showContent) {
            BBCodeContentView({
              nodes: getCachedBBNodes(this.resolveDisplayContent()),
              onImageClick: this.onImageClick,
              onLinkClick: this.onLinkClick,
            }).width('100%').margin({ top: 12 })
          }

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

        // 投票属于主题而非作者，主楼作者被屏蔽时仍应可投（官方 votec0 独立于正文渲染）
        if (this.post.vote.length > 0) {
          PostPoll({ post: this.post })
        }

        if (this.post.comments.length > 0) {
          PostComments({
            post: this.post,
            onImageClick: this.onImageClick,
            onLinkClick: this.onLinkClick,
            onProfileClick: this.onProfileClick,
          })
        }

        if (this.post.hotReplies.length > 0) {
          HotRepliesSection({
            post: this.post,
            onImageClick: this.onImageClick,
            onLinkClick: this.onLinkClick,
            onProfileClick: this.onProfileClick,
          })
        }
      }
      .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 }).alignItems(HorizontalAlign.Start)
  }

  /**
   * 楼层是否有标题（服务端每层可带 `subject`，多数楼层为空）。
   *
   * 主楼（`lou === 0`）的 `subject` 是**主题标题**，页面标题栏已经展示，卡片内不重复；
   * 判空用 `resolveFloorSubject`（解码 `&nbsp;` 等实体后判空），与树构建器同一口径。
   */
  private hasPostSubject(): boolean {
    return resolveFloorSubject(this.post).length > 0
  }

  /**
   * 楼层标题文本（纯文本：官方网页这里是 `<h3 id='postsubject{lou}'>`，不解析 BBCode）。
   *
   * 4 楼这类「只写了标题、正文只有引用头」的楼层，标题就是该层唯一的文字，
   * 客户端此前完全不渲染 `subject`，用户会以为内容被剔除（tid 47864458 的 4 楼）。
   *
   * @returns 解码后的楼层标题；主楼或无标题时为空串
   */
  private resolveSubjectText(): string {
    return resolveFloorSubject(this.post)
  }

  private getEditTimeDisplay(): string {
    if (!this.post.alterinfo || this.post.alterinfo.length === 0) return ''
    const et: number | null = parseAlterinfoTs(this.post.alterinfo)
    if (et === null) return ''
    return ' [在' + formatTimestampCST(et) + '修改]'
  }

  /**
   * 正文渲染内容：树模式传入的「剥离引用区正文」优先，未覆盖时使用原始 content。
   *
   * @returns 用于 BBCode 渲染的正文
   */
  private resolveDisplayContent(): string {
    return this.displayContent.length > 0 ? this.displayContent : this.post.content
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
