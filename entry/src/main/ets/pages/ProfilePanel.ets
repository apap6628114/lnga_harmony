import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { checkin } from '../service/api/FavoriteApi'
import { followUser } from '../service/api/FollowApi'
import { ApiResult } from '../model/NgaApiResults'
import { FollowListTab } from '../model/Follow'
import { ProfileData, ReputationData } from '../model/User'
import { AppColors, BreakpointType, ProfileActionIconColors } from '../common/constants/Constants'
import { formatTime, fmtNum, formatMoney, escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { Avatar } from '../common/components/Avatar'
import { MakeNoteDialog } from '../common/dialogs/Dialogs'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { LoadingStateView, ErrorStateView } from '../common/components/PageStateView'
import { SettingRow } from '../common/components/SettingRow'
import { getCachedBBNodes, preWarmBatch } from '../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from '../common/components/BBCodeContentView'
import { openImageViewer, handleForumLink } from '../common/utils/LinkUtils'
import { PageScope } from '../common/concurrency/PageScope'
import { Context } from '@kit.AbilityKit'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { scanBarcode, scanCore } from '@kit.ScanKit'
import { isNgaQrLoginUrl } from '../common/utils/NgaQrLoginUtils'

/**
 * 个人主页统计项数据模型（驱动 Grid 中的 ForEach）。
 * visible=false 的项不参与渲染（等价于原 if 条件分支）。
 */
class StatItem {
  iconRes: Resource = $r('app.media.icon_chat_bubble')
  label: string = ''
  value: string = ''
  visible: boolean = true
  /** 点击行为（null 表示纯展示不可点击）。 */
  action: (() => void) | null = null
}

@Component
export struct ProfilePanel {
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State errorMsg: string = ''
  @State profile: ProfileData | null = null
  @State checkinLoading: boolean = false
  @State checkinResult: string = ''
  /** 当前登录用户是否已关注主页用户（来自 ucp.get 的 follow 字段）。 */
  @State isFollowing: boolean = false
  /** 关注/取消关注请求是否进行中（防重复提交）。 */
  @State followLoading: boolean = false
  noteDialogController?: CustomDialogController

  private showNoteDialog(): void {
    this.noteDialogController = new CustomDialogController({
      builder: MakeNoteDialog({
        userName: this.profile?.userName ?? '',
        uid: this.uid,
        currentNote: appStore.settingsStore.getNote(this.uid),
        onConfirm: (note: string, uid: string, userName: string): void => {
          appStore.settingsStore.addOrUpdateNote(uid, userName, note)
          appStore.showToast('备注已保存')
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    })
    this.noteDialogController.open()
  }
  @StorageProp('profileVersion') @Watch('onProfileVersionChange') profileVersion: number = 0
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0
  /** 当前主页用户是否已被屏蔽。 */
  @State isProfileBlacklisted: boolean = false
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 滚动容器当前视口高度。 */
  @State scrollViewportHeight: number = 1
  /** 扫码页面是否正在打开，避免重复拉起系统扫码界面。 */
  @State qrScanLoading: boolean = false

  @Prop @Watch('onUidChange') uid: string = ''
  private isOwnProfile: boolean = false
  private uidInitialized: boolean = false
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()
  /** 个人主页滚动控制器。 */
  private scroller: Scroller = new Scroller()

  /** 按滚动容器绝对偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  /**
   * 拉起系统二维码扫描界面，并打开 NGA 扫码授权页面。
   */
  private async startQrLoginScan(): Promise<void> {
    if (this.qrScanLoading) {
      return
    }
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录 NGA')
      return
    }

    this.qrScanLoading = true
    try {
      const context: Context = this.getUIContext().getHostContext() as Context
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      })
      const qrUrl: string = result.originalValue.trim()
      if (!isNgaQrLoginUrl(qrUrl)) {
        appStore.showToast('请扫描 NGA 登录二维码')
        return
      }
      routerStore.navigateActivity(Screen.webview(qrUrl))
    } catch (e) {
      appStore.showToast('扫码已取消或失败')
    } finally {
      this.qrScanLoading = false
    }
  }

  aboutToAppear(): void {
    this.scope.begin()
    this.uidInitialized = true
    this.isOwnProfile = appStore.auth.uid === this.uid
    this.onBlacklistVersionChange()
    const cached = appStore.getCachedProfile(this.uid)
    if (cached) {
      this.profile = cached
      if (cached.sign) preWarmBatch([cached.sign])
      this.isLoading = false
    }
    this.syncFollowState()
    appStore.ensureProfile(this.uid)
  }

  /** 结束页面出现会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  private onUidChange(): void {
    if (!this.uidInitialized) {
      return
    }
    this.profile = null
    this.isFollowing = false
    this.titleScrollEffectProgress = 0
    this.isLoading = true
    this.hasError = false
    this.isOwnProfile = appStore.auth.uid === this.uid
    this.onBlacklistVersionChange()
    const cached = appStore.getCachedProfile(this.uid)
    if (cached) {
      this.profile = cached
      if (cached.sign) preWarmBatch([cached.sign])
      this.isLoading = false
    }
    this.syncFollowState()
    appStore.ensureProfile(this.uid)
  }

  /** 同步当前主页用户的黑名单状态。 */
  private onBlacklistVersionChange(): void {
    this.isProfileBlacklisted = appStore.settingsStore.isBlacklisted(this.uid)
  }

  private onProfileVersionChange(): void {
    const cached = appStore.getCachedProfile(this.uid)
    if (cached) {
      this.profile = cached
      if (cached.sign) preWarmBatch([cached.sign])
      this.isLoading = false
      this.hasError = false
    }
    this.syncFollowState()
  }

  /** 从当前资料同步关注状态（ucp.get 的 follow 字段，服务端条件返回）。 */
  private syncFollowState(): void {
    this.isFollowing = this.profile?.follow ?? false
  }

  /**
   * 切换对当前主页用户的关注状态（乐观更新，失败回滚）。
   */
  private async toggleFollow(): Promise<void> {
    if (this.followLoading || !this.profile) {
      return
    }
    const target: boolean = !this.isFollowing
    const previous: boolean = this.isFollowing
    this.isFollowing = target
    this.followLoading = true
    try {
      const result: ApiResult = await followUser(appStore.auth.token, this.profile.uid, target)
      if (result.ok) {
        this.profile.follow = target
        appStore.showToast(target ? '已关注' : '已取消关注')
        appStore.invalidateProfile(this.profile.uid)
      } else {
        this.isFollowing = previous
        appStore.showToast(result.error || '操作失败')
      }
    } catch (e) {
      this.isFollowing = previous
      appStore.showToast('操作失败')
    }
    this.followLoading = false
  }

  private getStatGridTemplate(): string {
    const cols: number = new BreakpointType(2, 3, 4).getValue(this.currentBreakpoint)
    let template: string = ''
    for (let i: number = 0; i < cols; i++) {
      template += '1fr '
    }
    return template.trim()
  }

  /**
   * 构造个人主页统计项数组（数据驱动 Grid ForEach）。
   * 当前四项：posts/rvrc 走 fmtNum，money 走 formatMoney；regdate 走 formatTime
   * 或兜底「未知」。
   * 按产品需求移除的统计展示（其信息另有落点）：
   * - 会员组：头像区已有 group 徽章（UID 旁）；
   * - 被关注/关注：入口移至操作列表（"我的关注"进入关注/粉丝列表）。
   * 威望按官方 App 口径展示 rvrc（ucp.get 实测 rvrc 与 fame 返回恒等值；
   * App 作者信息条「威望」列与威望页均显示 rvrc 直接值，js_ucp.js 的 fame/10
   * 为网页端旧展示逻辑，不再采用）。
   */
  private buildStatItems(): StatItem[] {
    const items: StatItem[] = []
    const p: ProfileData = this.profile!

    const s1: StatItem = new StatItem()
    s1.iconRes = $r('app.media.icon_chat_bubble')
    s1.label = '发帖数'
    s1.value = fmtNum(p.posts)
    items.push(s1)

    const s2: StatItem = new StatItem()
    s2.iconRes = $r('app.media.icon_money')
    s2.label = '金钱'
    s2.value = formatMoney(p.money)
    items.push(s2)

    const s3: StatItem = new StatItem()
    s3.iconRes = $r('app.media.icon_medal')
    s3.label = '威望'
    s3.value = fmtNum(p.rvrc)
    items.push(s3)

    const s4: StatItem = new StatItem()
    s4.iconRes = $r('app.media.icon_calendar')
    s4.label = '注册日期'
    s4.value = p.regdate ? formatTime(Number(p.regdate)) : '未知'
    items.push(s4)

    if (p.reputationEntryList.length > 0) {
      const s5: StatItem = new StatItem()
      s5.iconRes = $r('app.media.icon_shield')
      s5.label = '声望'
      // 学金钱样式：网格统计项展示「数值 名称」（如「181 N币」），多条换行
      s5.value = this.joinReputationValues(p.reputationEntryList)
      items.push(s5)
    }

    return items
  }

  /**
   * 拼接多版面声望条目为「数值 名称」多行文本（如 "181 N币\n-5 声望X"）。
   *
   * @param list - 声望条目列表
   * @returns 多行展示文本
   */
  private joinReputationValues(list: ReputationData[]): string {
    let out: string = ''
    for (let i = 0; i < list.length; i++) {
      if (i > 0) out += '\n'
      const value: string = list[i].value
      const name: string = list[i].name
      out += value.length > 0 ? value + ' ' + name : name
    }
    return out
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          Column() {
            LoadingStateView()
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 44 + this.statusBarHeight })
        } else if (this.hasError) {
          Column() {
            ErrorStateView({
              msg: this.errorMsg,
              onRetry: () => { this.isLoading = true; this.hasError = false; appStore.ensureProfile(this.uid) }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 44 + this.statusBarHeight })
        } else if (this.profile) {
          Scroll(this.scroller) {
            Column() {
              Column() {
                Column() {
                Avatar({ avatar: this.profile!.avatarUrl, uid: String(this.profile!.uid), name: this.profile!.userName, avatarSize: 64 })

              Text(unescapeHtml(this.profile!.userName))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .margin({ top: 8 })

              Row() {
                if (this.profile!.group) {
                  Text(unescapeHtml(this.profile!.group))
                    .fontSize(12)
                    .fontColor(AppColors.primary)
                    .backgroundColor(AppColors.primaryLight)
                    .borderRadius(4)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                }
                Text(`UID: ${escHtml(this.profile!.uid)}`)
                  .fontSize(13)
                  .fontColor(AppColors.textSecondary)
                  .margin({ left: 8 })

                if (this.profile!.ipLoc) {
                  Row() {
                    Image($r('app.media.icon_location')).width(13).height(13).fillColor(AppColors.textSecondary).margin({ right: 3 })
                    Text(unescapeHtml(this.profile!.ipLoc)).fontSize(13).fontColor(AppColors.textSecondary)
                  }.margin({ left: 8 })
                }
              }
              .margin({ top: 6 })

              if (this.profile!.title) {
                Text(unescapeHtml(this.profile!.title))
                  .fontSize(13)
                  .fontColor(AppColors.textTertiary)
                  .margin({ top: 6 })
              }
              if (this.profile!.honor) {
                Text(unescapeHtml(this.profile!.honor))
                  .fontSize(12)
                  .fontColor(AppColors.warning)
                  .fontWeight(FontWeight.Medium)
                  .margin({ top: 4 })
              }

              if (appStore.settingsStore.getNote(this.uid).length > 0) {
                Text('备注: ' + appStore.settingsStore.getNote(this.uid))
                  .fontSize(13)
                  .fontColor(AppColors.warning)
                  .margin({ top: 6 })
              }
            }
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 16 })

            Grid() {
              ForEach(this.buildStatItems(), (item: StatItem) => {
                GridItem() {
                  Column() {
                    Row() {
                      Image(item.iconRes).width(16).height(16).fillColor(AppColors.textSecondary)
                      Text(item.label).fontSize(11).fontColor(AppColors.textSecondary).margin({ left: 4 })
                    }
                    .alignItems(VerticalAlign.Center)
                    Text(item.value).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppColors.textPrimary).margin({ top: 4 })
                      .textAlign(TextAlign.Center)
                  }
                  .alignItems(HorizontalAlign.Center)
                  .width('100%')
                  .padding({ top: 9, bottom: 9 })
                }
                .onClick(() => {
                  if (item.action) {
                    item.action()
                  }
                })
              }, (item: StatItem) => item.label)
            }
            .columnsTemplate(this.getStatGridTemplate())
            .columnsGap(8)
            .rowsGap(8)
            .padding({ left: 16, right: 16, top: 6, bottom: 12 })
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .margin({ top: 12 })

            if (this.profile!.medal) {
              Column() {
                Text('勋章')
                  .fontSize(13)
                  .fontColor(AppColors.textSecondary)
                  .margin({ bottom: 4 })
                RichText(this.profile!.medal)
                  .width('100%')
              }
              .width('92%')
              .padding(16)
              .backgroundColor(AppColors.bgTertiary)
              .borderRadius(12)
              .margin({ top: 12 })
              .alignItems(HorizontalAlign.Start)
            }

            if (this.profile!.sign && this.profile!.sign.length > 0) {
              Column() {
                Text('签名')
                  .fontSize(13)
                  .fontColor(AppColors.textSecondary)
                  .margin({ bottom: 4 })
                BBCodeContentView({
                  nodes: getCachedBBNodes(this.profile!.sign),
                  onImageClick: (urls: string[], index: number): void => {
                    openImageViewer(urls, index)
                  },
                  onLinkClick: (href: string): void => {
                    handleForumLink(href, this.getUIContext().getHostContext() as Context)
                  },
                }).width('100%')
              }
              .width('92%')
              .padding(16)
              .backgroundColor(AppColors.bgTertiary)
              .borderRadius(12)
              .margin({ top: 12 })
              .alignItems(HorizontalAlign.Start)
            }

            if (this.isOwnProfile) {
              Column() {
                SettingRow({
                  iconRes: $r('app.media.icon_bell'), iconColor: ProfileActionIconColors.notifications, label: '我的消息',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.notifications())
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.profile_topics'), iconColor: ProfileActionIconColors.topics, label: '我的主题',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.topicList(this.profile!.userName + '的主题', -1, this.profile!.uid))
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.profile_replies'), iconColor: ProfileActionIconColors.replies, label: '我的回帖',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.topicList(this.profile!.userName + '的回帖', -1, this.profile!.uid, '', '1'))
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.icon_people'), iconColor: ProfileActionIconColors.history, label: '我的关注',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.followList(FollowListTab.FOLLOWED))
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.profile_favorites'), iconColor: ProfileActionIconColors.favorites, label: '收藏主题',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.favoriteSaved())
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.profile_history'), iconColor: ProfileActionIconColors.history, label: '浏览历史',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.browseHistory())
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)

                // 签到行 - 内联，不使用 @Builder
                Row() {
                  Stack() {
                    Image($r('app.media.profile_checkin'))
                      .width(17).height(17)
                      .fillColor(AppColors.white)
                  }
                  .width(29)
                  .height(29)
                  .borderRadius(6)
                  .backgroundColor(ProfileActionIconColors.checkin)
                  .margin({ right: 12 })

                  Text(this.checkinLoading ? '签到中...' : this.checkinResult || '每日签到')
                    .fontSize(17)
                    .layoutWeight(1)

                  Text('>')
                    .fontSize(16)
                    .fontColor(AppColors.chevron)
                }
                .width('100%')
                .height(44)
                .padding({ left: 16, right: 16 })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.checkinLoading = true
                  const gen: number = this.scope.begin()
                  checkin(appStore.auth.token).then((result) => {
                    if (!this.scope.isActive(gen)) {
                      return
                    }
                    if (result.ok) {
                      this.checkinResult = '签到成功'
                    } else {
                      this.checkinResult = result.error || '签到失败'
                    }
                    this.checkinLoading = false
                    appStore.showToast(this.checkinResult)
                    setTimeout(() => {
                      if (!this.scope.isAlive()) {
                        return
                      }
                      this.checkinResult = ''
                    }, 3000)
                  }).catch(() => {
                    if (!this.scope.isActive(gen)) {
                      return
                    }
                    this.checkinResult = '签到失败'
                    this.checkinLoading = false
                    appStore.showToast(this.checkinResult)
                  })
                })

                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.profile_settings'), iconColor: ProfileActionIconColors.settings, label: '设置',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.settings())
                  }
                })
              }
              .width('92%')
              .backgroundColor(AppColors.bgTertiary)
              .borderRadius(12)
              .margin({ top: 12 })
            } else {
              Row() {
                Button('发私信')
                  .fontSize(15)
                  .fontColor(AppColors.white)
                  .backgroundColor(AppColors.primary)
                  .borderRadius(12)
                  .layoutWeight(1)
                  .height(44)
                  .onClick(() => {
                    routerStore.navigateActivity(Screen.messages(this.profile!.userName))
                  })

                Button('备注')
                  .fontSize(15)
                  .fontColor(AppColors.warning)
                  .backgroundColor(AppColors.bgTertiary)
                  .borderRadius(12)
                  .height(44)
                  .margin({ left: 12 })
                  .onClick(() => { this.showNoteDialog() })
              }
              .width('92%')
              .margin({ top: 12 })

              Row() {
                Button('主题')
                  .fontSize(15)
                  .fontColor(AppColors.textPrimary)
                  .backgroundColor(AppColors.bgTertiary)
                  .borderRadius(12)
                  .layoutWeight(1)
                  .height(44)
                  .onClick(() => {
                    routerStore.navigateActivity(Screen.topicList(this.profile!.userName + '的主题', -1, this.profile!.uid))
                  })

                Button('回帖')
                  .fontSize(15)
                  .fontColor(AppColors.textPrimary)
                  .backgroundColor(AppColors.bgTertiary)
                  .borderRadius(12)
                  .layoutWeight(1)
                  .height(44)
                  .margin({ left: 12 })
                  .onClick(() => {
                    routerStore.navigateActivity(Screen.topicList(this.profile!.userName + '的回帖', -1, this.profile!.uid, '', '1'))
                  })

                if (!this.isOwnProfile) {
                  Button(this.isFollowing ? '已关注' : '关注')
                    .fontSize(15)
                    .fontColor(this.isFollowing ? AppColors.primary : AppColors.textPrimary)
                    .backgroundColor(AppColors.bgTertiary)
                    .borderRadius(12)
                    .layoutWeight(1)
                    .height(44)
                    .margin({ left: 12 })
                    .enabled(!this.followLoading)
                    .onClick(() => { this.toggleFollow() })

                  Button(this.isProfileBlacklisted ? '取消屏蔽' : '加黑')
                    .fontSize(15)
                    .fontColor(AppColors.destructive)
                    .backgroundColor(AppColors.bgTertiary)
                    .borderRadius(12)
                    .height(44)
                    .margin({ left: 12 })
                    .onClick(() => {
                      if (this.isProfileBlacklisted) {
                        if (appStore.settingsStore.removeBlacklist(this.profile!.uid)) {
                          appStore.showToast('已取消屏蔽')
                        }
                      } else if (appStore.settingsStore.addBlacklist({
                        userId: this.profile!.uid,
                        nickName: this.profile!.userName || `User${this.profile!.uid}`
                      })) {
                        appStore.showToast('已加入黑名单')
                      }
                    })
                }
              }
              .width('92%')
              .margin({ top: 12, bottom: 30 })
            }
          }
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 32 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.scrollViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height !== this.scrollViewportHeight) {
            this.scrollViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.bg)

    PanelNavBar({
      title: '个人主页',
      scrollEffectProgress: this.titleScrollEffectProgress,
      rightIcon: this.isOwnProfile ? $r('app.media.icon_scan') : '',
      rightIconAccessibilityText: this.isOwnProfile ? '扫一扫' : '',
      onRightClick: (): void => { this.startQrLoginScan() }
    })
      .width('100%').position({ x: 0, y: 0 })
  }
  .width('100%')
  .height('100%')
}
}
