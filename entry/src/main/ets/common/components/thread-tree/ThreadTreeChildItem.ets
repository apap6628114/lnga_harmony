import { AppColors } from '../../constants/Constants'
import { parseAlterinfoTs, formatTimestampCST } from '../../utils/Utils'
import { getCachedBBNodes } from '../../../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from '../BBCodeContentView'
import { Avatar } from '../Avatar'
import { AnonymousName } from '../AnonymousName'
import { PostAttachments } from '../post-item/PostAttachments'
import { PostVoteBar } from '../post-item/PostVoteBar'
import { PostInfo } from '../../../model/PostInfo'
import { VoteResult } from '../../../model/NgaApiResults'
import { ThreadTreeChild } from '../../../model/ThreadTree'
import { appStore } from '../../../store/AppStore'

/**
 * 两层递进树的第二层子节点行。
 *
 * 职责（`docs/THREAD_TREE_DESIGN.md` §3.3）：把一条「回复了某楼层」的楼层渲染成
 * 缩进一层的轻量行，自上而下：
 *
 * ```text
 * 头像 24  用户名 [楼主] [备注]                         #当前楼层号
 * 时间 [编辑时间]
 * 回复 @被回复者 #被回复楼层号  →（仅回复更深祖先时显示）
 * 正文（已剥离引用区）
 * 附件 / 动作栏
 * ```
 *
 * 「回复 @被回复者」放在**时间行与正文之间**（不在用户信息区）：它是阅读正文前的上下文提示，
 * 与该层正文属于同一视觉段落；字号 13vp 与用户名一致（回复关系是阅读主线，不能弱化成小字），
 * `→` 可点击跳到被回复楼层，`@名字` 可点击打开资料卡。
 *
 * **直接回复所属根的子行不显示关系行**（`showReplyTo=false`）：缩进已经表达它是根的一级
 * 回复，再写「回复楼主 / 回复根作者」是冗余噪音；只有跳过中间楼层、回复更深祖先的楼层
 * 才显示（#3 直接回复 #2 不显示，#4 回复 #3 时显示）。
 *
 * 不渲染签名、投票、贴条、热回复，保持子节点轻量。
 *
 * 引用区不再显示：树的两层关系已表达「回复了谁」，正文使用父组件传入的
 * `displayContent`（已剥离 `[quote]` 块与 `Reply to` 头）；剥离后无正文时不渲染正文块。
 *
 * 视觉定值（设计契约，不得自行改）：
 * - 左侧缩进 40vp（相对屏幕左边距）、右侧 16vp、上下 10vp；
 * - 左侧 2vp 通高竖线 `AppColors.separator`，与父根视觉串联；**无卡片底色**（透明）；
 * - 跳转定位命中时整行底色切 `AppColors.selectionTint`（`highlight` 驱动，120ms 过渡）；
 * - 头像 24vp，用户名与回复关系 13vp，辅助信息（时间/楼层号/备注）11vp。
 *
 * 黑名单：作者被屏蔽时只显示「该用户已被屏蔽」占位。`blacklistVersion` 的
 * `@StorageProp` 读取是**冗余依赖**（照抄 `PostItem.ets:37/80-83`），漏掉它组件
 * 就不再订阅黑名单变更，会出现「改黑名单后行不刷新」而不报错。
 */

/** 子节点行左侧缩进（vp，相对屏幕左边距，对应「第二层」缩进）。 */
const CHILD_INDENT: number = 40

/** 子节点行右侧内边距（vp）。 */
const CHILD_RIGHT_PADDING: number = 16

/** 子节点行上下内边距（vp）。 */
const CHILD_VERTICAL_PADDING: number = 10

/** 左侧层级竖线宽度（vp）。 */
const CHILD_RAIL_WIDTH: number = 2

/** 层级竖线与内容之间的间距（vp）。 */
const CHILD_RAIL_GAP: number = 10

/** 子节点头像尺寸（vp）。 */
const CHILD_AVATAR_SIZE: number = 24

/** 子节点用户名/回复关系字号（vp，设计要求两者一致）。 */
const CHILD_NAME_FONT_SIZE: number = 13

/** 子节点「回复 @被回复者」字号（vp，与用户名一致，避免看起来像小字备注）。 */
const CHILD_REPLY_FONT_SIZE: number = 13

/** 子节点辅助信息字号（时间、楼层号、备注，vp）。 */
const CHILD_META_FONT_SIZE: number = 11

/** 子节点用户名后「(备注)」字号（vp）。 */
const CHILD_NOTE_FONT_SIZE: number = 10

/** 子节点「→」跳转字号（vp，与用户名一致）。 */
const CHILD_JUMP_FONT_SIZE: number = 13

/** 子节点黑名单占位文案字号（vp）。 */
const CHILD_PLACEHOLDER_FONT_SIZE: number = 13

/** 高亮底色过渡动画时长（毫秒）。 */
const CHILD_HIGHLIGHT_ANIM_MS: number = 120

@Component
export struct ThreadTreeChildItem {
  /** 子节点数据（楼层 + 直接引用关系，@Prop 值拷贝） */
  @Prop child: ThreadTreeChild = new ThreadTreeChild()
  /** 被回复楼层号：0=楼主，-1=未知（不显示 `#N`） */
  @Prop targetLou: number = -1
  /** 树模式正文（已剥离引用区）；空串表示引用区后没有正文，不渲染正文块 */
  @Prop displayContent: string = ''
  /** 是否渲染正文块 */
  @Prop showContent: boolean = true
  /** 是否显示「回复 @被回复者」关系行：直接回复所属根时为 false（缩进已表达） */
  @Prop showReplyTo: boolean = false
  /** 是否已点赞 */
  @Prop isVotedUp: boolean = false
  /** 是否已踩 */
  @Prop isVotedDown: boolean = false
  /** 握姿：0=右手布局，1=左手布局 */
  @Prop holdingHand: number = 0
  /** 是否为主题作者（楼主），决定是否显示「楼主」标记 */
  @Prop isTopicAuthor: boolean = false
  /** 是否为本人的帖子（动作栏决定是否显示编辑按钮） */
  @Prop isOwnPost: boolean = false
  /** 跳转定位命中时整行高亮（父组件在约 2 秒后清除） */
  @Prop highlight: boolean = false
  /** 黑名单变更版本号（冗余读，建立响应式依赖，勿删） */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0
  /** 图片点击回调 */
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  /** 链接点击回调 */
  onLinkClick: (href: string) => void = (_href: string) => {}
  /** 视频点击回调（对齐 PostItem 签名；正文视频当前由 BBCodeContentView 内部处理） */
  onVideoClick: (url: string) => void = (_url: string) => {}
  /** 点击用户资料回调，传入 uid 与点击位置的屏幕坐标 */
  onProfileClick: (uid: string, screenX: number, screenY: number) => void =
    (_uid: string, _x: number, _y: number) => {}
  /** 点击「→」跳转到被回复楼层 */
  onJumpToPid: (pid: number) => void = (_pid: number) => {}
  /** 投票回调，value=1 为赞，-1 为踩；返回服务端最终状态供动作栏局部刷新。 */
  onVote: (post: PostInfo, value: number) => Promise<VoteResult> = async (_post: PostInfo, _value: number): Promise<VoteResult> => {
    const result: VoteResult = new VoteResult()
    result.error = '投票回调未设置'
    return result
  }
  /** 回复回调 */
  onReply: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 编辑回调 */
  onEdit: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 分享回调 */
  onShare: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** AI 总结回调 */
  onSummarize: (post: PostInfo) => void = (_post: PostInfo) => {}
  /** 朗读回调 */
  onReadAloud: (post: PostInfo) => void = (_post: PostInfo) => {}

  /**
   * 判断当前子节点作者是否已被屏蔽。
   *
   * @returns 作者是否在实时黑名单中
   */
  private isPostBlacklisted(): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(this.child.post.authorid))
  }

  /**
   * 当前楼层的显示时间：优先本地时间戳格式化，服务端字符串兜底。
   *
   * @returns 时间文案
   */
  private getPostTimeText(): string {
    const post: PostInfo = this.child.post
    if (post.postdatetimestamp > 0) {
      return formatTimestampCST(post.postdatetimestamp)
    }
    return post.postdate
  }

  /**
   * 编辑时间文案（形如 ` [在2026-11-04 10:00修改]`），无编辑记录时为空串。
   *
   * @returns 编辑时间文案
   */
  private getEditTimeText(): string {
    const alterinfo: string = this.child.post.alterinfo
    if (alterinfo.length === 0) {
      return ''
    }
    const editTs: number | null = parseAlterinfoTs(alterinfo)
    if (editTs === null) {
      return ''
    }
    return ' [在' + formatTimestampCST(editTs) + '修改]'
  }

  /**
   * 当前子节点自身的楼层号文案（与 `PostItemHeader` 同一规则，避免出现 `#0`）。
   *
   * @returns `楼主` / `沙发` / `#N`
   */
  private getLouLabel(): string {
    const lou: number = this.child.post.lou
    if (lou === 0) {
      return '楼主'
    }
    if (lou === 1) {
      return '沙发'
    }
    return '#' + String(lou)
  }

  /**
   * 被回复楼层号文案（调用处已保证 `targetLou >= 0`）。
   *
   * @returns `#楼主` / `#N`
   */
  private getTargetLouLabel(): string {
    if (this.targetLou === 0) {
      return '楼主'
    }
    return '#' + String(this.targetLou)
  }

  /**
   * 正文渲染内容：优先使用父组件传入的剥离引用区正文。
   *
   * @returns 正文内容
   */
  private resolveDisplayContent(): string {
    return this.displayContent.length > 0 ? this.displayContent : this.child.post.content
  }

  /**
   * 点击子节点作者区（头像 + 用户名）打开资料卡；匿名楼层只提示不弹卡。
   *
   * @param event - 点击事件（提供窗口坐标）
   */
  private handleAuthorClick(event: ClickEvent): void {
    if (this.child.post.isanonymous) {
      appStore.showToast('该用户已匿名')
      return
    }
    const uid: string = String(this.child.post.authorid)
    if (uid.length > 0) {
      this.onProfileClick(uid, event.windowX, event.windowY)
    }
  }

  /**
   * 点击「@被回复者」打开其资料卡；匿名 uid（`#anony_…`）只提示不弹卡。
   *
   * @param event - 点击事件（提供窗口坐标）
   */
  private handleTargetProfileClick(event: ClickEvent): void {
    const uid: string = this.child.ref.targetUid
    if (uid.length === 0) {
      return
    }
    if (uid.indexOf('#anony_') === 0) {
      appStore.showToast('该用户已匿名')
      return
    }
    this.onProfileClick(uid, event.windowX, event.windowY)
  }

  /**
   * 点击「→」跳转到被回复楼层（父组件负责展开折叠的根并定位）。
   */
  private handleJumpToPid(): void {
    const pid: number = this.child.ref.targetPid
    if (pid > 0) {
      this.onJumpToPid(pid)
    }
  }

  build() {
    Row() {
      Column() {
        Row() {
          Avatar({
            avatar: this.child.post.avatar,
            uid: String(this.child.post.authorid),
            name: this.child.post.author,
            avatarSize: CHILD_AVATAR_SIZE
          })
            .margin({ right: 8 })

          Column() {
            Row() {
              AnonymousName({
                author: this.child.post.author,
                isAnonymous: this.child.post.isanonymous,
                fontSize: CHILD_NAME_FONT_SIZE,
                normalColor: AppColors.primary,
                isMuted: this.child.post.isMuted
              })
              if (this.child.post.userNote.length > 0) {
                Text('(' + this.child.post.userNote + ')')
                  .fontSize(CHILD_NOTE_FONT_SIZE).fontColor(AppColors.warning).margin({ left: 4 })
              }
              if (this.isTopicAuthor) {
                Text('楼主')
                  .fontSize(CHILD_META_FONT_SIZE).fontColor(AppColors.primary)
                  .fontWeight(FontWeight.Medium).margin({ left: 4 })
              }
              Blank()
              Text(this.getLouLabel())
                .fontSize(CHILD_META_FONT_SIZE).fontColor(AppColors.textTertiary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .onClick((event: ClickEvent): void => { this.handleAuthorClick(event) })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.isPostBlacklisted()) {
          Text('该用户已被屏蔽')
            .fontSize(CHILD_PLACEHOLDER_FONT_SIZE).fontColor(AppColors.textTertiary)
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 8 })
            .padding({ top: 10, bottom: 10 })
        } else {
          Row() {
            Text(this.getPostTimeText())
              .fontSize(CHILD_META_FONT_SIZE).fontColor(AppColors.textTertiary)
            if (this.getEditTimeText().length > 0) {
              Text(this.getEditTimeText())
                .fontSize(CHILD_META_FONT_SIZE).fontColor(AppColors.textTertiary)
            }
          }
          .margin({ top: 4 })

          if (this.showReplyTo &&
            (this.child.ref.targetAuthor.length > 0 || this.child.ref.targetPid > 0)) {
            Row() {
              Text('回复')
                .fontSize(CHILD_REPLY_FONT_SIZE).fontColor(AppColors.textSecondary)
              if (this.child.ref.targetAuthor.length > 0) {
                Text('@' + this.child.ref.targetAuthor)
                  .fontSize(CHILD_REPLY_FONT_SIZE).fontColor(AppColors.primary)
                  .margin({ left: 3 })
                  .onClick((event: ClickEvent): void => { this.handleTargetProfileClick(event) })
              }
              if (this.targetLou >= 0) {
                Text(this.getTargetLouLabel())
                  .fontSize(CHILD_META_FONT_SIZE).fontColor(AppColors.textTertiary)
                  .margin({ left: 4 })
              }
              if (this.child.ref.targetPid > 0) {
                Text('→')
                  .fontSize(CHILD_JUMP_FONT_SIZE).fontColor(AppColors.primary)
                  .fontWeight(FontWeight.Medium)
                  .padding({ left: 6, right: 4, top: 2, bottom: 2 })
                  .onClick((): void => { this.handleJumpToPid() })
              }
            }
            .margin({ top: 6 })
            .alignItems(VerticalAlign.Center)
          }

          if (this.showContent) {
            BBCodeContentView({
              nodes: getCachedBBNodes(this.resolveDisplayContent()),
              onImageClick: this.onImageClick,
              onLinkClick: this.onLinkClick,
            })
              .width('100%')
              .margin({ top: 8 })
          }

          if (this.child.post.attachs.length > 0) {
            PostAttachments({
              post: this.child.post,
              onImageClick: this.onImageClick,
            })
          }

          PostVoteBar({
            post: this.child.post,
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
      }
      .layoutWeight(1)
      .padding({ left: CHILD_RAIL_GAP })
      .border({ width: { left: CHILD_RAIL_WIDTH }, color: AppColors.separator })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({
      left: CHILD_INDENT,
      right: CHILD_RIGHT_PADDING,
      top: CHILD_VERTICAL_PADDING,
      bottom: CHILD_VERTICAL_PADDING
    })
    .backgroundColor(this.highlight ? AppColors.selectionTint : Color.Transparent)
    .animation({ duration: CHILD_HIGHLIGHT_ANIM_MS })
    .alignItems(VerticalAlign.Center)
  }
}
