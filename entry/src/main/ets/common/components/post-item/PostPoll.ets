import { AppColors } from '../../constants/Constants'
import { PostInfo } from '../../../model/PostInfo'
import { VoteInfo, VoteOption } from '../../../model/Vote'
import { parseVote, votePercent, barPercent, scoreValue } from '../../../parser/VoteParser'
import { submitPollVote } from '../../../service/api/VoteApi'
import { appStore } from '../../../store/AppStore'
import { formatTimestampCST } from '../../utils/Utils'

/**
 * 投票帖投票组件。
 *
 * 渲染在主楼正文之后，对应官方网页 `votec0` 容器（js_read.js commonui.vote/voteDefault）：
 * - type 0 投票：选项行（标题 | 选择控件 | N票 | 百分比 | 进度条）+ 提交按钮
 * - type 1 投注：双指标行（票数列 + 投注铜币列，官方 voteBet 布局），结算时标"胜出"
 * - type 2 评分：均分行（官方 voteScore 布局，scoNum/voteNum 两位小数 + 相对 max 进度条）
 * - type 3/4 评分单条/问答：只读标题列表
 * - 信息行：按类型拼装"共计N人... [结束时间] [结果查看限制]"
 * - 未结束且已登录时显示选择控件与提交按钮；提交走 nuke.php?__lib=vote&__act=vote
 * - 提交成功后乐观更新票数并隐藏选择控件（服务端拒绝重复投票时会返回错误提示）
 */
@Component
export struct PostPoll {
  /** 所属帖子信息（仅主楼携带 vote 数据） */
  @Prop post: PostInfo = new PostInfo()
  /** 当前选中的选项 ID */
  @State private selectedIds: string[] = []
  /** 是否提交中 */
  @State private submitting: boolean = false
  /** 本次会话已投（提交成功后隐藏选择控件） */
  @State private submitted: boolean = false
  /** 解码后的投票数据（提交成功后乐观更新票数） */
  @State private voteData: VoteInfo = new VoteInfo()

  aboutToAppear(): void {
    const parsed: VoteInfo | null = parseVote(this.post.vote)
    if (parsed) {
      this.voteData = parsed
    }
    this.restoreSubmitted()
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.selectedIds = []
    this.submitting = false
    this.submitted = false
    const parsed: VoteInfo | null = parseVote(this.post.vote)
    if (parsed) {
      this.voteData = parsed
    } else {
      // 新帖 vote 不可解析时清空旧帖数据，避免复用残留
      this.voteData = new VoteInfo()
    }
    this.restoreSubmitted()
  }

  /**
   * 从本地持久化恢复"已投"状态（提交成功后标记，重进页面不显示待投票控件）。
   */
  private restoreSubmitted(): void {
    if (this.submitted || this.post.vote.length === 0) {
      return
    }
    const uid: string = appStore.auth.uid
    appStore.loadPollVoted(uid).then((tids: string[]) => {
      // 异步返回时组件可能已复用/切换登录：uid 与当前登录一致且 tid 归属当前帖才标记
      if (appStore.auth.uid !== uid) {
        return
      }
      for (let i: number = 0; i < tids.length; i++) {
        if (tids[i] === String(this.post.tid)) {
          this.submitted = true
          break
        }
      }
    }).catch((e: Error) => {
    })
  }

  /**
   * 投票是否仍开放：未设置结束时间或当前时间未到结束时间。
   */
  private isActive(): boolean {
    if (this.voteData.end <= 0) {
      return true
    }
    const nowSec: number = Math.floor(Date.now() / 1000)
    return nowSec <= this.voteData.end
  }

  private isLoggedIn(): boolean {
    return appStore.auth.token.length > 0
  }

  /**
   * 是否可以交互投票：类型为投票、未结束、已登录、未提交。
   */
  private canVote(): boolean {
    return this.voteData.type === 0 && this.isActive() && this.isLoggedIn() && !this.submitted
  }

  /**
   * 单选还是多选：max_select>1 为多选（checkbox），否则单选（radio）。
   */
  private isMultiSelect(): boolean {
    return this.voteData.maxSelect > 1
  }

  private isOptionSelected(id: string): boolean {
    for (let i: number = 0; i < this.selectedIds.length; i++) {
      if (this.selectedIds[i] === id) {
        return true
      }
    }
    return false
  }

  private onOptionTap(opt: VoteOption): void {
    if (!this.canVote() || this.submitting) {
      return
    }
    if (this.isMultiSelect()) {
      const next: string[] = []
      let removed: boolean = false
      for (let i: number = 0; i < this.selectedIds.length; i++) {
        if (this.selectedIds[i] === opt.id) {
          removed = true
        } else {
          next.push(this.selectedIds[i])
        }
      }
      if (!removed) {
        if (this.voteData.maxSelect > 0 && next.length >= this.voteData.maxSelect) {
          appStore.showToast('最多选择' + this.voteData.maxSelect + '项')
          return
        }
        next.push(opt.id)
      }
      this.selectedIds = next
    } else {
      this.selectedIds = [opt.id]
    }
  }

  private onTapSubmit(): void {
    if (this.submitting || this.selectedIds.length === 0) {
      return
    }
    this.submitting = true
    // LazyForEach 复用下组件实例可能被复用于其他帖子，回调须按 tid 比对，
    // 避免慢请求返回时对错误帖子做乐观更新
    const submitTid: number = this.post.tid
    submitPollVote(appStore.auth.token, submitTid, this.selectedIds).then((result) => {
      if (submitTid !== this.post.tid) {
        return
      }
      this.submitting = false
      if (result.ok) {
        appStore.showToast(result.message || '投票成功')
        this.applyLocalResult()
        this.submitted = true
        this.selectedIds = []
        appStore.markPollVoted(appStore.auth.uid, String(submitTid))
      } else {
        appStore.showToast(result.error || '投票失败')
        if (result.error === '未登录') {
          this.submitted = true
        } else if (this.isAlreadyVotedError(result.error)) {
          // 服务端拒绝重复投票（换设备/清数据后本地记录丢失）：同样标记已投
          this.submitted = true
          this.selectedIds = []
          appStore.markPollVoted(appStore.auth.uid, String(submitTid))
        }
      }
    }).catch((e: Error) => {
      if (submitTid !== this.post.tid) {
        return
      }
      this.submitting = false
      appStore.showToast((e as Error).message || '投票失败')
    })
  }

  /**
   * 服务端"已投过票"类错误判定（错误文本来自服务端，宽松匹配）。
   */
  private isAlreadyVotedError(err: string): boolean {
    if (err.indexOf('已投') >= 0) {
      return true
    }
    if (err.indexOf('投票') >= 0 && err.indexOf('重复') >= 0) {
      return true
    }
    return err.indexOf('已经') >= 0 && err.indexOf('投') >= 0
  }

  /**
   * 提交成功后乐观更新票数：选中选项各 +1，参与人数 +1。
   */
  private applyLocalResult(): void {
    const updated: VoteInfo = new VoteInfo()
    updated.raw = this.voteData.raw
    updated.type = this.voteData.type
    updated.opt = this.voteData.opt
    updated.maxSelect = this.voteData.maxSelect
    updated.min = this.voteData.min
    updated.max = this.voteData.max
    updated.end = this.voteData.end
    updated.priv = this.voteData.priv
    updated.done = this.voteData.done
    const options: VoteOption[] = []
    for (let i: number = 0; i < this.voteData.options.length; i++) {
      const src: VoteOption = this.voteData.options[i]
      const opt: VoteOption = new VoteOption()
      opt.id = src.id
      opt.title = src.title
      opt.voteNum = src.voteNum
      opt.scoNum = src.scoNum
      if (this.isOptionSelected(src.id)) {
        opt.voteNum = src.voteNum + 1
      }
      options.push(opt)
    }
    updated.options = options
    updated.userSum = this.voteData.userSum + 1
    updated.voteSum = this.voteData.voteSum + this.selectedIds.length
    updated.scoSum = this.voteData.scoSum
    this.voteData = updated
  }

  /**
   * 指标值：useSco=true 取投注量（type 1），否则取票数（type 0）。
   */
  private metricOf(opt: VoteOption, useSco: boolean): number {
    return useSco ? opt.scoNum : opt.voteNum
  }

  /**
   * 指标总和：useSco=true 取总投注量，否则取总票数。
   */
  private metricSum(useSco: boolean): number {
    return useSco ? this.voteData.scoSum : this.voteData.voteSum
  }

  /**
   * 单项显示百分比：((值/组总和*1000)|0)/10，与官方 votePercentString 一致。
   */
  private percentOf(opt: VoteOption, useSco: boolean): number {
    return votePercent(this.metricOf(opt, useSco), this.metricSum(useSco))
  }

  /**
   * 进度条宽度百分比：官方 voteFormatGroup 将组内最高项归一化到 75% 宽度。
   */
  private barPercentOf(opt: VoteOption, useSco: boolean): number {
    let most: number = 0
    for (let i: number = 0; i < this.voteData.options.length; i++) {
      const v: number = this.metricOf(this.voteData.options[i], useSco)
      if (v > most) {
        most = v
      }
    }
    return barPercent(this.metricOf(opt, useSco), this.metricSum(useSco), most)
  }

  /**
   * type 2 评分：单项均分两位小数（官方 voteScore 的 scc 语义）。
   */
  private scoreOf(opt: VoteOption): number {
    return scoreValue(opt.scoNum, opt.voteNum)
  }

  /**
   * type 2 评分进度条宽度：((均分/最高分*1000)|0)/10，官方 voteBar(scc,x.max,1) 语义。
   */
  private scoreBarPercentOf(opt: VoteOption): number {
    if (this.voteData.max <= 0) {
      return 0
    }
    return votePercent(this.scoreOf(opt), this.voteData.max)
  }

  /**
   * 投注帖结算选项判定：done 为逗号包裹串，含选项 ID 即"胜出"（官方 x.done 语义）。
   */
  private isSettledWinner(opt: VoteOption): boolean {
    if (this.voteData.done.length === 0) {
      return false
    }
    return (',' + this.voteData.done + ',').indexOf(',' + opt.id + ',') >= 0
  }

  /**
   * 卡片标题（官方 voteDefault/voteBet/voteScore 的 name 变量）。
   */
  private cardTitle(): string {
    if (this.voteData.type === 1) {
      return '投注'
    }
    if (this.voteData.type === 2 || this.voteData.type === 3) {
      return '评分'
    }
    if (this.voteData.type === 4) {
      return '问答'
    }
    return '投票'
  }

  /**
   * 信息行文本：按类型拼装，与官方 voteDefault/voteBet/voteScore 的 info 语义对齐。
   */
  private infoText(): string {
    if (this.voteData.type === 1) {
      let s: string = '共计' + this.voteData.userSum + '人投注 共计' + this.voteData.voteSum + '票' +
        ' 投注' + this.voteData.scoSum + '铜币 最少' + this.voteData.min + ' 最多' + this.voteData.max
      if (this.voteData.done.length > 0) {
        s += ' 已结算'
      }
      s += this.commonInfoSuffix()
      return s
    }
    if (this.voteData.type === 2) {
      let s: string = '共计' + this.voteData.userSum + '人评分(' + this.voteData.min + '~' + this.voteData.max + ')'
      s += this.commonInfoSuffix()
      return s
    }
    let s: string = '共计' + this.voteData.userSum + '人' + this.cardTitle() + ' 共计' + this.metricSum(false) + '票'
    if (this.voteData.maxSelect > 1) {
      s += ' 最多选择' + this.voteData.maxSelect + '项'
    }
    s += this.commonInfoSuffix()
    return s
  }

  private commonInfoSuffix(): string {
    let s: string = ''
    if (this.voteData.end > 0) {
      s += ' 结束时间 ' + formatTimestampCST(this.voteData.end)
    }
    if ((this.voteData.opt & 1) !== 0) {
      s += ' 提交后可查看结果'
    }
    if ((this.voteData.opt & 2) !== 0) {
      s += ' 结束后可查看结果'
    }
    return s
  }

  build() {
    if (this.voteData.options.length > 0) {
      Column() {
      Row() {
        Text(this.cardTitle())
          .fontSize(14)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .padding({ left: 12, top: 8, bottom: 8 })
      .backgroundColor(AppColors.bgTertiary)
      .borderRadius({ topLeft: 8, topRight: 8 })

      Column() {
        ForEach(this.voteData.options, (opt: VoteOption, index: number) => {
          if (this.voteData.type === 1) {
            this.OptionRowBet(opt)
          } else if (this.voteData.type === 2) {
            this.OptionRowScore(opt)
          } else if (this.voteData.type === 3 || this.voteData.type === 4) {
            this.OptionRowSimple(opt, index)
          } else {
            this.OptionRowVote(opt)
          }
          // key 含票数/投注量/总和因子：乐观更新后所有行重建，票数、百分比（依赖总和）同步刷新。
          // 仅用 opt.id 时 key 不变，ForEach diff 复用旧 item，行内容不更新
        }, (opt: VoteOption) => opt.id + '#' + opt.voteNum + '#' + opt.scoNum +
          '#' + this.voteData.voteSum + '#' + this.voteData.scoSum)
      }
      .width('100%')

      Column() {
        Row() {
          Text(this.infoText())
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
        }
        .width('100%')

        if (this.canVote()) {
          Row() {
            Text(this.submitting ? '提交中...' : '提交投票')
              .fontSize(13)
              .fontColor(AppColors.white)
              .padding({ left: 18, right: 18, top: 6, bottom: 6 })
          }
          .backgroundColor(this.selectedIds.length > 0 && !this.submitting ? AppColors.primary : AppColors.textTertiary)
          .borderRadius(16)
          .margin({ top: 10 })
          .onClick(() => this.onTapSubmit())
        } else if (this.submitted) {
          Row() {
            Text('已投票')
              .fontSize(11)
              .fontColor(AppColors.success)
          }
          .margin({ top: 8 })
        } else if (!this.isActive()) {
          Row() {
            Text('投票已结束')
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
          }
          .margin({ top: 8 })
        } else if (!this.isLoggedIn() && this.voteData.type === 0) {
          Row() {
            Text('登录后可投票')
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
          }
          .margin({ top: 8 })
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(AppColors.bg)
      .borderRadius({ bottomLeft: 8, bottomRight: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ top: 12 })
    .borderRadius(8)
    .clip(true)
    }
  }

  @Builder
  OptionRowVote(opt: VoteOption) {
    Column() {
      Row() {
        if (this.canVote()) {
          Row() {
            if (this.isOptionSelected(opt.id)) {
              if (this.isMultiSelect()) {
                Text('✓').fontSize(10).fontColor(AppColors.white)
              } else {
                Row().width(6).height(6).borderRadius(3).backgroundColor(AppColors.white)
              }
            }
          }
          .width(16)
          .height(16)
          .borderRadius(this.isMultiSelect() ? 4 : 8)
          .border({ width: 1, color: this.isOptionSelected(opt.id) ? AppColors.primary : AppColors.textTertiary })
          .backgroundColor(this.isOptionSelected(opt.id) ? AppColors.primary : Color.Transparent)
          .justifyContent(FlexAlign.Center)
          .onClick(() => this.onOptionTap(opt))
        }

        Text(opt.title)
          .fontSize(14)
          .fontColor(AppColors.textPrimary)
          .layoutWeight(1)
          .margin({ left: 8 })

        if (this.canVote()) {
          Row().width(8)
        }

        Text(opt.voteNum + '票')
          .fontSize(12)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 8 })

        Text(this.percentOf(opt, false) + '%')
          .fontSize(12)
          .fontColor(AppColors.textSecondary)
          .width(52)
          .textAlign(TextAlign.End)
          .margin({ left: 8 })

        Row() {
          Row().width(this.barPercentOf(opt, false) + '%')
            .height(8)
            .backgroundColor(AppColors.primary)
            .borderRadius(4)
        }
        .width(96)
        .height(8)
        .backgroundColor(AppColors.separator)
        .borderRadius(4)
        .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      if (opt !== this.voteData.options[this.voteData.options.length - 1]) {
        Divider().color(AppColors.separator).strokeWidth(0.5)
      }
    }
    .width('100%')
  }

  /**
   * 投注帖行：票数 + 投注量双指标（官方 voteBet 布局）。
   */
  @Builder
  OptionRowBet(opt: VoteOption) {
    Column() {
      Row() {
        Text(opt.title)
          .fontSize(14)
          .fontColor(AppColors.textPrimary)
          .layoutWeight(1)
          .margin({ left: 8 })

        if (this.isSettledWinner(opt)) {
          Text('胜出')
            .fontSize(11)
            .fontColor(AppColors.destructive)
            .fontWeight(FontWeight.Medium)
            .margin({ left: 8 })
        }

        Text(opt.voteNum + '票')
          .fontSize(12)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 8 })

        Text(this.percentOf(opt, false) + '%')
          .fontSize(12)
          .fontColor(AppColors.textSecondary)
          .width(44)
          .textAlign(TextAlign.End)
          .margin({ left: 8 })

        Row() {
          Row().width(this.barPercentOf(opt, false) + '%')
            .height(8)
            .backgroundColor(AppColors.primary)
            .borderRadius(4)
        }
        .width(80)
        .height(8)
        .backgroundColor(AppColors.separator)
        .borderRadius(4)
        .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      Row() {
        Text('投注' + opt.scoNum + '铜币')
          .fontSize(12)
          .fontColor(AppColors.textSecondary)
          .layoutWeight(1)
          .margin({ left: 8 })

        Text(this.percentOf(opt, true) + '%')
          .fontSize(12)
          .fontColor(AppColors.textSecondary)
          .width(44)
          .textAlign(TextAlign.End)
          .margin({ left: 8 })

        Row() {
          Row().width(this.barPercentOf(opt, true) + '%')
            .height(8)
            .backgroundColor(AppColors.warning)
            .borderRadius(4)
        }
        .width(80)
        .height(8)
        .backgroundColor(AppColors.separator)
        .borderRadius(4)
        .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, bottom: 8 })

      if (opt !== this.voteData.options[this.voteData.options.length - 1]) {
        Divider().color(AppColors.separator).strokeWidth(0.5)
      }
    }
    .width('100%')
  }

  /**
   * 评分帖行：均分 + 进度条（官方 voteScore 布局）。
   */
  @Builder
  OptionRowScore(opt: VoteOption) {
    Column() {
      Row() {
        Text(opt.title)
          .fontSize(14)
          .fontColor(AppColors.textPrimary)
          .layoutWeight(1)
          .margin({ left: 8 })

        Text(this.scoreOf(opt) + '分')
          .fontSize(12)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 8 })

        Row() {
          Row().width(this.scoreBarPercentOf(opt) + '%')
            .height(8)
            .backgroundColor(AppColors.primary)
            .borderRadius(4)
        }
        .width(96)
        .height(8)
        .backgroundColor(AppColors.separator)
        .borderRadius(4)
        .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      if (opt !== this.voteData.options[this.voteData.options.length - 1]) {
        Divider().color(AppColors.separator).strokeWidth(0.5)
      }
    }
    .width('100%')
  }

  /**
   * 评分单条/问答帖行：仅标题列表（官方 TYPE_SCORE_VOTE/TYPE_QACHART 布局，无统计）。
   */
  @Builder
  OptionRowSimple(opt: VoteOption, index: number) {
    Column() {
      Row() {
        if (this.voteData.type === 4) {
          Text((index + 1) + '. ')
            .fontSize(14)
            .fontColor(AppColors.textTertiary)
        }

        Text(opt.title)
          .fontSize(14)
          .fontColor(AppColors.textPrimary)
          .layoutWeight(1)
          .margin({ left: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      if (opt !== this.voteData.options[this.voteData.options.length - 1]) {
        Divider().color(AppColors.separator).strokeWidth(0.5)
      }
    }
    .width('100%')
  }
}
