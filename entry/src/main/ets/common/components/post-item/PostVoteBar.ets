import { AppColors } from '../../constants/Constants'
import { PostInfo } from '../../../model/PostInfo'
import { VoteResult } from '../../../model/NgaApiResults'

/**
 * 帖子投票/动作栏子组件。
 *
 * 渲染点赞、踩、回复、编辑、分享、AI 总结、朗读等动作按钮。根据握姿
 * （holdingHand，1=左手布局）切换按钮排布顺序。展开/收起额外动作菜单（menuExpanded）
 * 时使用 150ms 动画。自持 menuExpanded，在组件复用时（aboutToReuse）重置为 false。
 */
@Component
export struct PostVoteBar {
  /** 所属帖子信息（@Prop 值拷贝） */
  @Prop post: PostInfo = new PostInfo()
  /** 是否已点赞（用于动作栏首次挂载时初始化局部状态） */
  @Prop isVotedUp: boolean = false
  /** 是否已踩（用于动作栏首次挂载时初始化局部状态） */
  @Prop isVotedDown: boolean = false
  /** 握姿：0=右手布局，1=左手布局（动作按钮靠左） */
  @Prop holdingHand: number = 0
  /** 是否为本人的帖子（决定是否显示编辑按钮） */
  @Prop isOwnPost: boolean = false
  /** 动作菜单展开状态 */
  @State private menuExpanded: boolean = false
  /** 动作栏当前显示的推荐分数。 */
  @State private displayScore: number = 0
  /** 动作栏当前显示的反对分数。 */
  @State private displayScore2: number = 0
  /** 动作栏当前显示的点赞状态。 */
  @State private displayVotedUp: boolean = false
  /** 动作栏当前显示的点踩状态。 */
  @State private displayVotedDown: boolean = false
  /** 是否正在等待投票接口返回，防止同一楼层重复提交。 */
  @State private voteSubmitting: boolean = false
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

  aboutToReuse(params: Record<string, Object>): void {
    this.menuExpanded = false
    this.voteSubmitting = false
    this.syncVoteBarFromProps()
  }

  aboutToAppear(): void {
    this.syncVoteBarFromProps()
  }

  /**
   * 从父组件输入同步动作栏初始状态。
   *
   * 点赞成功后的数字与颜色由动作栏自己的 @State 局部更新，避免为了刷新一个动作栏
   * 而重建包含正文和图片的整个帖子楼层。
   */
  private syncVoteBarFromProps(): void {
    if (this.voteSubmitting) {
      return
    }
    this.displayScore = this.post.score
    this.displayScore2 = this.post.score_2
    this.displayVotedUp = this.isVotedUp
    this.displayVotedDown = this.isVotedDown
  }

  /**
   * 提交点赞或点踩，成功时保留本次点击的局部状态，失败时回滚。
   *
   * @param value - 1 表示点赞，-1 表示点踩
   */
  private submitVote(value: number): void {
    if (this.voteSubmitting) {
      return
    }
    const requestPid: number = this.post.pid
    const requestScore: number = this.displayScore
    const requestScore2: number = this.displayScore2
    const requestVotedUp: boolean = this.displayVotedUp
    const requestVotedDown: boolean = this.displayVotedDown
    const optimisticState: number = this.resolveNextVoteState(value, requestVotedUp, requestVotedDown)
    this.voteSubmitting = true
    this.applyVoteState(optimisticState, requestScore, requestScore2, requestVotedUp, requestVotedDown)
    this.onVote(this.post, value).then((result: VoteResult): void => {
      if (requestPid === this.post.pid) {
        if (!result.ok) {
          this.restoreVoteState(requestScore, requestScore2, requestVotedUp, requestVotedDown)
        }
      }
      this.voteSubmitting = false
    }).catch((): void => {
      if (requestPid === this.post.pid) {
        this.restoreVoteState(requestScore, requestScore2, requestVotedUp, requestVotedDown)
      }
      this.voteSubmitting = false
    })
  }

  /**
   * 根据当前局部状态计算一次点击操作的乐观最终状态。
   *
   * @param value - 1 表示点赞，-1 表示点踩
   * @param votedUp - 点击前的点赞状态
   * @param votedDown - 点击前的点踩状态
   * @returns 1=点赞、-1=点踩、0=取消
   */
  private resolveNextVoteState(value: number, votedUp: boolean, votedDown: boolean): number {
    if (value === 1) {
      return votedUp ? 0 : 1
    }
    return votedDown ? 0 : -1
  }

  /**
   * 按指定最终状态计算并写入动作栏局部分数与颜色。
   *
   * @param nextState - 1=点赞、-1=点踩、0=取消
   * @param previousScore - 操作前点赞分数
   * @param previousScore2 - 操作前点踩分数
   * @param previousVotedUp - 操作前点赞状态
   * @param previousVotedDown - 操作前点踩状态
   */
  private applyVoteState(nextState: number, previousScore: number, previousScore2: number,
    previousVotedUp: boolean, previousVotedDown: boolean): void {
    const nextUp: boolean = nextState === 1
    const nextDown: boolean = nextState === -1
    this.displayScore = previousScore + (nextUp ? 1 : 0) - (previousVotedUp ? 1 : 0)
    this.displayScore2 = previousScore2 + (nextDown ? 1 : 0) - (previousVotedDown ? 1 : 0)
    this.displayVotedUp = nextUp
    this.displayVotedDown = nextDown
  }

  /**
   * 回滚接口失败或异常时的动作栏状态。
   *
   * @param score - 回滚后的点赞分数
   * @param score2 - 回滚后的点踩分数
   * @param votedUp - 回滚后的点赞状态
   * @param votedDown - 回滚后的点踩状态
   */
  private restoreVoteState(score: number, score2: number, votedUp: boolean, votedDown: boolean): void {
    this.displayScore = score
    this.displayScore2 = score2
    this.displayVotedUp = votedUp
    this.displayVotedDown = votedDown
  }

  build() {
    Row() {
       if (this.holdingHand === 1) {
         Row() {
           Row() {
             Row() {
               Image($r('app.media.icon_more'))
                 .width(16).height(16)
                 .fillColor(this.menuExpanded ? AppColors.primary : AppColors.textTertiary)
                 .rotate({ angle: this.menuExpanded ? -90 : 0 })
             }
             .padding({ left: 6, right: 6, top: 4, bottom: 4 })
             .borderRadius(6)
             .alignItems(VerticalAlign.Center)
             .onClick(() => { this.getUIContext()?.animateTo({ duration: 150, curve: Curve.EaseInOut }, () => { this.menuExpanded = !this.menuExpanded }) })

              if (this.menuExpanded) {
                Row() {
                  Image($r('app.media.icon_ai'))
                    .width(16).height(16)
                    .fillColor(AppColors.textTertiary)
                }
                .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                .borderRadius(6)
                .margin({ left: 6 })
                .alignItems(VerticalAlign.Center)
                .transition(TransitionEffect.OPACITY)
                .onClick(() => this.onSummarize(this.post))

                Row() {
                  Image($r('app.media.icon_volume_up'))
                    .width(16).height(16)
                    .fillColor(AppColors.textTertiary)
                }
                .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                .borderRadius(6)
                .margin({ left: 6 })
                .alignItems(VerticalAlign.Center)
                .transition(TransitionEffect.OPACITY)
                .onClick(() => this.onReadAloud(this.post))

                Row() {
                  Image($r('app.media.icon_share'))
                    .width(16).height(16)
                    .fillColor(AppColors.textTertiary)
                }
                .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                .borderRadius(6)
                .margin({ left: 6 })
                .alignItems(VerticalAlign.Center)
                .transition(TransitionEffect.OPACITY)
                .onClick(() => this.onShare(this.post))
              }

              if (this.isOwnPost) {
               Row() {
                 Image($r('app.media.icon_compose'))
                   .width(16).height(16)
                   .fillColor(AppColors.textTertiary)
               }
               .padding({ left: 6, right: 6, top: 4, bottom: 4 })
               .borderRadius(6)
               .margin({ left: 6 })
               .alignItems(VerticalAlign.Center)
               .onClick(() => this.onEdit(this.post))
             }

             Row() {
               Image($r('app.media.icon_reply'))
                 .width(16).height(16)
                 .fillColor(AppColors.textTertiary)
             }
             .padding({ left: 6, right: 6, top: 4, bottom: 4 })
             .borderRadius(6)
             .margin({ left: 6 })
             .alignItems(VerticalAlign.Center)
             .onClick(() => this.onReply(this.post))

             Row() {
                 Image($r('app.media.icon_thumb_down'))
                   .width(16).height(16)
                   .fillColor(this.displayVotedDown ? AppColors.destructive : AppColors.textTertiary)
                 if (this.displayScore2 > 0 || this.displayVotedDown) {
                   Text(String(this.displayScore2))
                   .fontSize(13)
                   .fontColor(this.displayVotedDown ? AppColors.destructive : AppColors.textSecondary)
                   .margin({ left: 3 })
                 }
             }
             .padding({ left: 6, right: 6, top: 4, bottom: 4 })
             .borderRadius(6)
             .margin({ left: 6 })
             .alignItems(VerticalAlign.Center)
             .onClick(() => this.submitVote(-1))

             Row() {
               Image($r('app.media.icon_thumb_up'))
                 .width(16).height(16)
                 .fillColor(this.displayVotedUp ? AppColors.primary : AppColors.textTertiary)
               if (this.displayScore > 0 || this.displayVotedUp) {
                 Text(String(this.displayScore))
                  .fontSize(13)
                  .fontColor(this.displayVotedUp ? AppColors.primary : AppColors.textSecondary)
                  .margin({ left: 3 })
               }
             }
             .padding({ left: 6, right: 6, top: 4, bottom: 4 })
             .borderRadius(6)
             .margin({ left: 6 })
             .alignItems(VerticalAlign.Center)
             .onClick(() => this.submitVote(1))
           }
           .alignItems(VerticalAlign.Center)
           .transition(TransitionEffect.OPACITY)

            Row().layoutWeight(1)
          }
       } else {
         Row().layoutWeight(1)
        Row() {
          Row() {
            Image($r('app.media.icon_thumb_up'))
              .width(16).height(16)
              .fillColor(this.displayVotedUp ? AppColors.primary : AppColors.textTertiary)
            if (this.displayScore > 0 || this.displayVotedUp) {
              Text(String(this.displayScore))
                .fontSize(13)
                .fontColor(this.displayVotedUp ? AppColors.primary : AppColors.textSecondary)
                .margin({ left: 3 })
            }
          }
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .borderRadius(6)
          .alignItems(VerticalAlign.Center)
          .onClick(() => this.submitVote(1))

          Row() {
            Image($r('app.media.icon_thumb_down'))
              .width(16).height(16)
              .fillColor(this.displayVotedDown ? AppColors.destructive : AppColors.textTertiary)
            if (this.displayScore2 > 0 || this.displayVotedDown) {
              Text(String(this.displayScore2))
                .fontSize(13)
                .fontColor(this.displayVotedDown ? AppColors.destructive : AppColors.textSecondary)
                .margin({ left: 3 })
            }
          }
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .borderRadius(6)
          .margin({ left: 6 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => this.submitVote(-1))

          Row() {
            Image($r('app.media.icon_reply'))
              .width(16).height(16)
              .fillColor(AppColors.textTertiary)
          }
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .borderRadius(6)
          .margin({ left: 6 })
          .alignItems(VerticalAlign.Center)
           .onClick(() => this.onReply(this.post))

          if (this.isOwnPost) {
            Row() {
              Image($r('app.media.icon_compose'))
                .width(16).height(16)
                .fillColor(AppColors.textTertiary)
            }
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(6)
            .margin({ left: 6 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => this.onEdit(this.post))
          }

          if (this.menuExpanded) {
            Row() {
              Image($r('app.media.icon_share'))
                .width(16).height(16)
                .fillColor(AppColors.textTertiary)
            }
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(6)
            .margin({ left: 6 })
            .alignItems(VerticalAlign.Center)
            .transition(TransitionEffect.OPACITY)
            .onClick(() => this.onShare(this.post))

            Row() {
              Image($r('app.media.icon_ai'))
                .width(16).height(16)
                .fillColor(AppColors.textTertiary)
            }
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(6)
            .margin({ left: 6 })
            .alignItems(VerticalAlign.Center)
            .transition(TransitionEffect.OPACITY)
            .onClick(() => this.onSummarize(this.post))

            Row() {
              Image($r('app.media.icon_volume_up'))
                .width(16).height(16)
                .fillColor(AppColors.textTertiary)
            }
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .borderRadius(6)
            .margin({ left: 6 })
            .alignItems(VerticalAlign.Center)
            .transition(TransitionEffect.OPACITY)
            .onClick(() => this.onReadAloud(this.post))
          }

          Row() {
            Image($r('app.media.icon_more'))
              .width(16).height(16)
              .fillColor(this.menuExpanded ? AppColors.primary : AppColors.textTertiary)
              .rotate({ angle: this.menuExpanded ? 90 : 0 })
          }
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .borderRadius(6)
          .margin({ left: 6 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.getUIContext()?.animateTo({ duration: 150, curve: Curve.EaseInOut }, () => { this.menuExpanded = !this.menuExpanded }) })
        }
        .alignItems(VerticalAlign.Center)
        .transition(TransitionEffect.OPACITY)
      }
    }.width('100%').margin({ top: 12 }).alignItems(VerticalAlign.Center)
  }
}
