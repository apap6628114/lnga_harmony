import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { checkin } from '../service/api/FavoriteApi'
import { ProfileData, ReputationData } from '../model/User'
import { AppColors, BreakpointType, ProfileActionIconColors } from '../common/constants/Constants'
import { formatTime, fmtNum, escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { Avatar } from '../common/components/Avatar'
import { AnonymousName } from '../common/components/AnonymousName'
import { MakeNoteDialog } from '../common/dialogs/Dialogs'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { LoadingStateView, ErrorStateView } from '../common/components/PageStateView'
import { SettingRow } from '../common/components/SettingRow'
import { getCachedBBNodes, preWarmBatch } from '../parser/bbcode/BBCodeCache'
import { BBCodeContentView } from '../common/components/BBCodeContentView'
import { openImageViewer, handleForumLink } from '../common/utils/LinkUtils'
import { PageScope } from '../common/concurrency/PageScope'
import { Context } from '@kit.AbilityKit'

/**
 * 个人主页统计项数据模型（驱动 Grid 中的 ForEach）。
 * visible=false 的项不参与渲染（等价于原 if 条件分支）。
 */
class StatItem {
  iconRes: Resource = $r('app.media.icon_chat_bubble')
  label: string = ''
  value: string = ''
  visible: boolean = true
}

@Component
export struct ProfilePanel {
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State errorMsg: string = ''
  @State profile: ProfileData | null = null
  /** 当前账号的未查看通知数量。 */
  @StorageProp('unreadNotiCount') unreadNotifications: number = 0
  /** 当前账号的未查看私信通知数量。 */
  @StorageProp('unreadMessageCount') unreadMessages: number = 0
  @State checkinLoading: boolean = false
  @State checkinResult: string = ''
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

  @Prop @Watch('onUidChange') uid: string = ''
  private isOwnProfile: boolean = false
  private uidInitialized: boolean = false
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()

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
  }

  private formatBadge(count: number): string {
    if (count <= 0) return ''
    if (count > 99) return '99+'
    return String(count)
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
   * 格式化规则与原 7 个硬编码 GridItem 逐字一致：
   * posts/money/rvrc 走 fmtNum；regdate 走 formatTime 或兜底「未知」；
   * group 兜底「普通会员」；fame/followByNum 仅在 >0 时显示。
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
    s2.value = fmtNum(p.money)
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

    const s5: StatItem = new StatItem()
    s5.iconRes = $r('app.media.icon_people')
    s5.label = '会员组'
    s5.value = p.group || '普通会员'
    items.push(s5)

    if (Number(p.fame) > 0) {
      const s6: StatItem = new StatItem()
      s6.iconRes = $r('app.media.icon_star')
      s6.label = '声望'
      s6.value = fmtNum(p.fame)
      items.push(s6)
    }

    if (Number(p.followByNum) > 0) {
      const s7: StatItem = new StatItem()
      s7.iconRes = $r('app.media.icon_shield')
      s7.label = '被关注'
      s7.value = p.followByNum
      items.push(s7)
    }

    return items
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
          Scroll() {
            Column() {
              Row().width('100%').height(44 + this.statusBarHeight)

              Column() {
                Column() {
                Avatar({ avatar: this.profile!.avatarUrl, uid: String(this.profile!.uid), name: this.profile!.userName, avatarSize: 80 })

              Text(unescapeHtml(this.profile!.userName))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .margin({ top: 12 })

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
              .margin({ top: 8 })

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
            .padding({ top: 24 })

            Grid() {
              ForEach(this.buildStatItems(), (item: StatItem) => {
                GridItem() {
                  Column() {
                    Row() {
                      Image(item.iconRes).width(16).height(16).fillColor(AppColors.textSecondary)
                      Text(item.label).fontSize(12).fontColor(AppColors.textSecondary).margin({ left: 4 })
                    }
                    .alignItems(VerticalAlign.Center)
                    Text(item.value).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppColors.textPrimary).margin({ top: 6 })
                  }
                  .alignItems(HorizontalAlign.Center)
                  .width('100%')
                  .padding({ top: 12, bottom: 12 })
                }
              }, (item: StatItem) => item.label)
            }
            .columnsTemplate(this.getStatGridTemplate())
            .columnsGap(8)
            .rowsGap(8)
            .padding({ left: 16, right: 16, top: 8, bottom: 16 })
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

            if (this.profile!.reputationEntryList && this.profile!.reputationEntryList.length > 0) {
              Column() {
                Text('威望记录')
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColors.textSecondary)
                  .padding({ top: 12, bottom: 4, left: 16, right: 16 })

                ForEach(this.profile!.reputationEntryList, (entry: ReputationData, index: number) => {
                  Column() {
                    Row() {
                      Text(entry.reputation > 0 ? `+${entry.reputation}` : `${entry.reputation}`)
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(entry.reputation > 0 ? AppColors.success : entry.reputation < 0 ? AppColors.destructive : AppColors.textTertiary)
                      Text(entry.time ? formatTime(entry.time) : '')
                        .fontSize(12)
                        .fontColor(AppColors.textTertiary)
                        .layoutWeight(1)
                        .textAlign(TextAlign.End)
                    }
                    .width('100%')
                    if (entry.topicSubject) {
                      Text(unescapeHtml(entry.topicSubject))
                        .fontSize(13)
                        .fontColor(AppColors.textPrimary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 2 })
                        .width('100%')
                    }
                    if (entry.postContent) {
                      Text(unescapeHtml(entry.postContent))
                        .fontSize(12)
                        .fontColor(AppColors.textTertiary)
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 2 })
                        .width('100%')
                    }
                    Row() {
                      Text('来自: ').fontSize(12).fontColor(AppColors.textTertiary)
                      AnonymousName({
                        author: entry.author ?? '',
                        isAnonymous: (entry.author ?? '').startsWith('#anony_') &&
                          (entry.author ?? '').length === 39,
                        fontSize: 12
                      })
                    }
                      .margin({ top: 2 })
                      .width('100%')
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .border({ width: { top: index === 0 ? 0 : 0.5 }, color: AppColors.separator })
                  .alignItems(HorizontalAlign.Start)
                }, (entry: ReputationData, index: number) => `${index}`)
              }
              .width('92%')
              .backgroundColor(AppColors.bgTertiary)
              .borderRadius(12)
              .margin({ top: 12 })
              .alignItems(HorizontalAlign.Start)
              .clip(true)
            }

            if (this.isOwnProfile) {
              Column() {
                SettingRow({
                  iconRes: $r('app.media.profile_messages'), iconColor: ProfileActionIconColors.messages, label: '私信',
                  badge: this.formatBadge(this.unreadMessages),
                  onAction: () => {
                    routerStore.navigateActivity(Screen.messages())
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.profile_notifications'), iconColor: ProfileActionIconColors.notifications, label: '通知',
                  badge: this.formatBadge(this.unreadNotifications),
                  onAction: () => {
                    routerStore.navigateActivity(Screen.notifications())
                  }
                })
                Divider().margin({ left: 60 }).color(AppColors.separator)
                SettingRow({
                  iconRes: $r('app.media.profile_favorites'), iconColor: ProfileActionIconColors.favorites, label: '收藏主题',
                  onAction: () => {
                    routerStore.navigateActivity(Screen.favoriteFolders())
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
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.bg)

    PanelNavBar({ title: '个人主页' })
      .width('100%').position({ x: 0, y: 0 })
  }
  .width('100%')
  .height('100%')
}
}
