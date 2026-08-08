import { appStore } from '../../store/AppStore'
import { routerStore, Screen } from '../../store/RouterStore'
import { ProfileData, AdminForumsData } from '../../model/User'
import { AppColors } from '../constants/Constants'
import { formatTime, fmtNum, escHtml, getAvatarUrl } from '../utils/Utils'
import { unescapeHtml } from '../../parser/_shared/HtmlEntityCodec'
import { Avatar } from './Avatar'
import { MakeNoteDialog } from '../dialogs/Dialogs'
import { PageScope } from '../concurrency/PageScope'
import { openImageViewer } from '../utils/LinkUtils'

import { getUserActivityAnalysis } from '../../service/api/UserApi'
import type { UserActivityAnalysis, ForumStat } from '../../model/NgaApiResults'
import { getActiveAiValidationMessage } from '../../service/ai/ActiveAiService'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../constants/AppStorageKeys'
import { UIMaterialManager } from '../managers/UIMaterialManager'

@Component
export struct ProfileCardPopup {
  @Prop targetUid: string = ''
  @Prop currentBreakpoint: string = 'sm'
  @State profile: ProfileData | null = null
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @StorageProp('profileVersion') @Watch('onProfileVersionChange') profileVersion: number = 0
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0
  @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) materialEnabled: boolean = true
  /** 当前资料卡用户是否已被屏蔽。 */
  @State isProfileBlacklisted: boolean = false
  onClose: () => void = () => {}
  noteDialogController?: CustomDialogController
  @State isAnalyzing: boolean = false
  /** 组件存活会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()

  /** 组件消失时结束会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  private async startAnalysis(): Promise<void> {
    if (this.isAnalyzing) return
    const aiValidationMessage: string = getActiveAiValidationMessage()
    if (aiValidationMessage.length > 0) {
      appStore.showToast(aiValidationMessage)
      return
    }
    this.isAnalyzing = true
    const gen: number = this.scope.begin()
    try {
      const result: UserActivityAnalysis | null = await getUserActivityAnalysis(
        appStore.auth.token,
        this.targetUid
      )
      // 弹窗可能已关闭：不再执行路由跳转与提示
      if (!this.scope.isActive(gen)) {
        return
      }
      if (result && (result.topicCount > 0 || result.replyCount > 0)) {
        const userName: string = this.profile?.userName ?? ''
        let prompt: string = ''
        prompt += userName + '(UID:' + this.targetUid + ') 的账号分析：\n'
        prompt += '共 ' + result.topicCount.toString() + ' 个主题，' +
          result.replyCount.toString() + ' 条回复\n\n'
        prompt += '活跃版面：\n'
        for (let i: number = 0; i < result.forumList.length; i++) {
          const f: ForumStat = result.forumList[i]
          prompt += '  ' + f.name + ': ' + (f.topicCount + f.replyCount).toString() + ' 帖\n'
        }
        prompt += '\n发帖时段：\n'
        const hd: number[] = result.hourDistribution
        let dawnSum: number = 0
        let morningSum: number = 0
        let afternoonSum: number = 0
        let nightSum: number = 0
        for (let i: number = 0; i <= 5; i++) { dawnSum += (hd.length > i ? hd[i] : 0) || 0 }
        for (let i: number = 6; i <= 11; i++) { morningSum += (hd.length > i ? hd[i] : 0) || 0 }
        for (let i: number = 12; i <= 17; i++) { afternoonSum += (hd.length > i ? hd[i] : 0) || 0 }
        for (let i: number = 18; i <= 23; i++) { nightSum += (hd.length > i ? hd[i] : 0) || 0 }
        prompt += '  凌晨: ' + dawnSum.toString() + ' 帖\n'
        prompt += '  上午: ' + morningSum.toString() + ' 帖\n'
        prompt += '  下午: ' + afternoonSum.toString() + ' 帖\n'
        prompt += '  晚上: ' + nightSum.toString() + ' 帖\n'
        if (result.topicSubjects.length > 0) {
          prompt += '\n发表的主题：\n'
          for (let i: number = 0; i < result.topicSubjects.length; i++) {
            prompt += '  ' + (i + 1).toString() + '. ' + result.topicSubjects[i] + '\n'
          }
        }
        if (result.replySnippets.length > 0) {
          prompt += '\n回复内容：\n'
          for (let i: number = 0; i < result.replySnippets.length; i++) {
            prompt += '  ' + (i + 1).toString() + '. ' + result.replySnippets[i] + '\n'
          }
        }
        this.getUIContext().getRouter().pushUrl({
          url: 'pages/ai/AiChatPage',
          params: {
            initialPrompt: prompt,
            title: 'AI 成分分析',
            scenario: 'user_analysis'
          }
        })
      } else {
        appStore.showToast('该用户暂无公开记录')
      }
    } catch (e) {
      appStore.showToast('分析请求失败')
    }
    this.isAnalyzing = false
  }

  private showNoteDialog(): void {
    this.noteDialogController = new CustomDialogController({
      builder: MakeNoteDialog({
        userName: this.profile?.userName ?? '',
        uid: this.targetUid,
        currentNote: appStore.settingsStore.getNote(this.targetUid),
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

  aboutToAppear(): void {
    this.scope.begin()
    this.onBlacklistVersionChange()
    const cached = appStore.getCachedProfile(this.targetUid)
    if (cached) {
      this.profile = cached
      this.isLoading = false
    }
    appStore.ensureProfile(this.targetUid)
  }

  /** 同步当前资料卡用户的黑名单状态。 */
  private onBlacklistVersionChange(): void {
    this.isProfileBlacklisted = appStore.settingsStore.isBlacklisted(this.targetUid)
  }

  private onProfileVersionChange(): void {
    const cached = appStore.getCachedProfile(this.targetUid)
    if (cached) {
      this.profile = cached
      this.isLoading = false
      this.hasError = false
    }
  }

  private navigateProfile(uid: string): void {
    this.onClose()
    routerStore.navigateActivity(Screen.profile(uid))
  }

  private navigateAuthorPosts(uid: string, name: string, searchpost: boolean): void {
    this.onClose()
    routerStore.navigateActivity(Screen.topicList(
      name + (searchpost ? '的回帖' : '的主题'), -1, uid, '', searchpost ? '1' : ''
    ))
  }

  /**
   * 使用帖子图片预览器展示用户头像。
   *
   * @param profile - 当前资料卡的用户资料
   */
  private openAvatarImage(profile: ProfileData): void {
    const avatarUrl: string = getAvatarUrl(profile.avatarUrl, profile.uid)
    if (avatarUrl.length === 0) return
    openImageViewer([avatarUrl], 0)
  }

  private joinForumNames(forums: AdminForumsData[]): string {
    const names: string[] = []
    for (let i = 0; i < forums.length; i++) {
      names.push(forums[i].forumName)
    }
    return names.join(', ')
  }

  private joinTitleHonor(title: string, honor: string): string {
    const parts: string[] = []
    if (title && title.length > 0) parts.push(title)
    if (honor && honor.length > 0) parts.push(honor)
    return parts.join(' · ')
  }

  build() {
    Column() {
      if (this.isLoading) {
        this.LoadingContent()
      } else if (this.hasError) {
        this.ErrorContent()
      } else if (this.profile) {
        this.ProfileContent(this.profile!)
      }
    }
    .width(280)
    .backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.bg)
    .borderRadius(14)
    .shadow({ radius: 16, color: AppColors.shadowLight, offsetY: 4 })
    .clip(true)
    .systemMaterial(this.materialEnabled ? UIMaterialManager.surfaceMaterial : undefined)
  }

  @Builder
  LoadingContent() {
    Column() {
      LoadingProgress().width(20).height(20).color(AppColors.textTertiary)
      Text('加载中...').fontSize(14).fontColor(AppColors.textTertiary).margin({ top: 8 })
    }
    .width('100%')
    .padding(32)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ErrorContent() {
    Column() {
      Text('获取用户信息失败').fontSize(14).fontColor(AppColors.textTertiary)
    }
    .width('100%')
    .padding(32)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ProfileContent(profile: ProfileData) {
    Column() {
      Row() {
        Avatar({ avatar: profile.avatarUrl, uid: profile.uid, name: profile.userName, avatarSize: 50 })
          .onClick((): void => {
            this.openAvatarImage(profile)
          })

        Column() {
          Row() {
            Text(unescapeHtml(profile.userName))
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
            if (profile.group && profile.group.length > 0) {
              Text(unescapeHtml(profile.group))
                .fontSize(10).fontColor(AppColors.textSecondary)
                .backgroundColor(AppColors.bgSecondary).borderRadius(4)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 }).margin({ left: 6 })
            }
            if (profile.muteTime && profile.muteTime.length > 0) {
              Text('禁言中')
                .fontSize(10).fontColor(AppColors.white)
                .backgroundColor(AppColors.destructive).borderRadius(4)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 }).margin({ left: 4 })
            }
          }
          .alignItems(VerticalAlign.Center)

          if (profile.title || profile.honor) {
            Text(unescapeHtml(this.joinTitleHonor(profile.title, profile.honor)))
              .fontSize(12).fontColor(AppColors.textSecondary).margin({ top: 3 })
          }

          Text(`UID: ${escHtml(profile.uid)}`)
            .fontSize(11).fontColor(AppColors.textTertiary).margin({ top: 3 })

          if (appStore.settingsStore.getNote(profile.uid).length > 0) {
            Text('备注: ' + appStore.settingsStore.getNote(profile.uid))
              .fontSize(11).fontColor(AppColors.warning).margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16 })
      .alignItems(VerticalAlign.Center)

      if (Number(profile.posts) || Number(profile.fame) || Number(profile.rvrc) || Number(profile.money)) {
        Row() {
          if (Number(profile.posts)) {
            this.StatItem(fmtNum(profile.posts), '发帖')
          }
          if (Number(profile.fame)) {
            this.StatItem(fmtNum(profile.fame), '威望')
          }
          if (Number(profile.rvrc)) {
            this.StatItem(fmtNum(profile.rvrc), 'RVRC')
          }
          if (Number(profile.money)) {
            this.StatItem(fmtNum(profile.money), '金钱')
          }
        }
        .width('100%')
        .backgroundColor(AppColors.bgSecondary)
        .borderRadius(8)
        .padding(6)
        .margin({ top: 12 })
      }

      Column() {
        this.DetailRows(profile)

        if (profile.sign && profile.sign.length > 0) {
          Text(unescapeHtml(profile.sign))
            .fontSize(12).fontColor(AppColors.textTertiary)
            .margin({ top: 8 })
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .padding({ left: 16, right: 16 })
      .width('100%')

      Row() {
        Text('主题').fontSize(12).fontColor(AppColors.primary).layoutWeight(1).textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .onClick(() => this.navigateAuthorPosts(profile.uid, profile.userName, false))
        Divider().vertical(true).height(16).alignSelf(ItemAlign.Center).color(AppColors.separator)
        Text('回帖').fontSize(12).fontColor(AppColors.primary).layoutWeight(1).textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .onClick(() => this.navigateAuthorPosts(profile.uid, profile.userName, true))
        Divider().vertical(true).height(16).alignSelf(ItemAlign.Center).color(AppColors.separator)
        Text(appStore.settingsStore.getNote(profile.uid).length > 0 ? '编辑备注' : '备注')
          .fontSize(12)
          .fontColor(AppColors.primary)
          .layoutWeight(1).textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .onClick(() => { this.showNoteDialog() })
        Divider().vertical(true).height(16).alignSelf(ItemAlign.Center).color(AppColors.separator)
        Text(this.isAnalyzing ? '分析中...' : '查成分')
          .fontSize(12)
          .fontColor(this.isAnalyzing ? AppColors.textTertiary : AppColors.primary)
          .layoutWeight(1).textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .onClick(() => { this.startAnalysis() })
        if (profile.uid !== appStore.auth.uid) {
          Divider().vertical(true).height(16).alignSelf(ItemAlign.Center).color(AppColors.separator)
          Text(this.isProfileBlacklisted ? '取消屏蔽' : '屏蔽')
            .fontSize(12)
            .fontColor(this.isProfileBlacklisted ?
              AppColors.textPrimary : AppColors.destructive)
            .layoutWeight(1).textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              if (this.isProfileBlacklisted) {
                if (appStore.settingsStore.removeBlacklist(profile.uid)) {
                  appStore.showToast('已取消屏蔽')
                }
              } else if (appStore.settingsStore.addBlacklist({
                userId: profile.uid,
                nickName: profile.userName || `User${profile.uid}`
              })) {
                appStore.showToast('已加入黑名单')
              }
            })
        }
      }
      .width('100%')
      .border({ width: { top: 0.5 }, color: AppColors.separator })
      .margin({ top: 8 })

      if (this.isAnalyzing) {
        Row() {
          LoadingProgress().width(16).height(16).color(AppColors.primary)
          Text('正在获取发言记录...').fontSize(12).fontColor(AppColors.textSecondary).margin({ left: 8 })
        }
        .width('100%')
        .padding(12)
        .justifyContent(FlexAlign.Center)
        .border({ width: { top: 0.5 }, color: AppColors.separator })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: 0 })
  }

  @Builder
  StatItem(value: string, label: string) {
    Column() {
      Text(value).fontSize(13).fontWeight(FontWeight.Medium).fontColor(AppColors.textPrimary)
      Text(label).fontSize(10).fontColor(AppColors.textTertiary).margin({ top: 1 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  DetailRows(profile: ProfileData) {
    Column() {
      if (profile.regdate) {
        this.DetailRow('注册日期', formatTime(Number(profile.regdate)))
      }
      if (profile.ipLoc) {
        this.DetailRow('IP属地', profile.ipLoc)
      }
      if (profile.followByNum && Number(profile.followByNum) > 0) {
        this.DetailRow('被关注', profile.followByNum)
      }
      if (profile.adminForums && profile.adminForums.length > 0) {
        this.DetailRow('管理版面', this.joinForumNames(profile.adminForums))
      }
    }
    .width('100%')
    .margin({ top: 4 })
  }

  @Builder
  DetailRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(12).fontColor(AppColors.textSecondary)
      Text(unescapeHtml(value)).fontSize(12).fontColor(AppColors.textPrimary).fontWeight(FontWeight.Medium)
        .layoutWeight(1).textAlign(TextAlign.End).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }
}
