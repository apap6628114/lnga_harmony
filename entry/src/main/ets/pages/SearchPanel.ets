/**
 * 搜索面板
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { getTopicList, createTopicListParams, searchForum } from '../service/api/ForumApi'
import type { TopicListParams } from '../service/api/ForumApi'
import type { TopicListResult, SearchForumResult } from '../model/NgaApiResults'
import { AppColors, FONT_COLORS, BreakpointType } from '../common/constants/Constants'
import { formatTime, escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { ThreadDataSource } from '../common/datasource/LazyDataSource'
import { AnonymousName } from '../common/components/AnonymousName'
import { PageScope } from '../common/concurrency/PageScope'
import {
  ReadingFontRole,
  ReadingLineHeightRole,
  ReadingTypography
} from '../common/typography/ReadingTypography'
import { preferences } from '@kit.ArkData'
import { Context } from '@kit.AbilityKit'

@Component
export struct SearchPanel {
  @State keyword: string = ''
  @State submitted: string = ''
  @State currentTab: number = 0
  @State history: string[] = []
  @State isLoading: boolean = false
  @State threads: object[] = []
  @State forums: object[] = []
  @State currentPage: number = 1
  @State totalPages: number = 0
  @State isLoadingMore: boolean = false
  @State showEmpty: boolean = false
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('topicFontSize') topicFontSize: number = 15
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0

  private scroller: Scroller = new Scroller()
  private forumsDataSource: ThreadDataSource = new ThreadDataSource()
  private threadsDataSource: ThreadDataSource = new ThreadDataSource()
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()

  aboutToAppear(): void {
    this.scope.begin()
    this.loadHistory()
  }

  /** 结束页面出现会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  private getSubjectFontColor(titleFont: string): ResourceColor {
    const num = Number(titleFont) || 0
    const color = num & 0x1f
    if (FONT_COLORS[color]) return FONT_COLORS[color]
    return AppColors.textPrimary
  }

  private isSubjectBold(titleFont: string): boolean {
    return (Number(titleFont) & 32) !== 0
  }

  private isSubjectItalic(titleFont: string): boolean {
    return (Number(titleFont) & 64) !== 0
  }

  private getTypeTags(type: number): string {
    if (type & 1024) return '[锁定]'
    return ''
  }

  /**
   * 判断搜索结果中的主题作者是否已被屏蔽。
   *
   * @param thread - 主题列表项
   * @returns 作者是否在实时黑名单中
   */
  private isAuthorBlacklisted(thread: Record<string, Object>): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(thread['authorId'] ?? ''))
  }

  /**
   * 判断搜索结果摘要对应的回复作者是否已被屏蔽。
   *
   * @param thread - 主题列表项
   * @returns 摘要作者是否在实时黑名单中
   */
  private isPreviewAuthorBlacklisted(thread: Record<string, Object>): boolean {
    const authorId: string = String(thread['previewAuthorId'] ?? '')
    return this.blacklistVersion >= 0 &&
      authorId.length > 0 &&
      appStore.settingsStore.isBlacklisted(authorId)
  }

  private async loadHistory(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as Context
      const pref = await preferences.getPreferences(ctx, 'nga_app_store')
      const raw = (await pref.get('search_history', '[]')) as string
      this.history = JSON.parse(raw) as string[]
    } catch (e) {
      this.history = []
    }
  }

  private async saveHistory(kw: string): Promise<void> {
    try {
      const list = this.history.filter((k: string) => k !== kw)
      list.unshift(kw)
      if (list.length > 20) list.length = 20
      this.history = [...list]
      const ctx = this.getUIContext().getHostContext() as Context
      const pref = await preferences.getPreferences(ctx, 'nga_app_store')
      await pref.put('search_history', JSON.stringify(list))
      await pref.flush()
    } catch (e) { /* ignore */ }
  }

  private async removeHistory(kw: string): Promise<void> {
    this.history = this.history.filter((k: string) => k !== kw)
    try {
      const ctx = this.getUIContext().getHostContext() as Context
      const pref = await preferences.getPreferences(ctx, 'nga_app_store')
      await pref.put('search_history', JSON.stringify(this.history))
      await pref.flush()
    } catch (e) { /* ignore */ }
  }

  private async clearHistoryAll(): Promise<void> {
    this.history = []
    try {
      const ctx = this.getUIContext().getHostContext() as Context
      const pref = await preferences.getPreferences(ctx, 'nga_app_store')
      await pref.put('search_history', '[]')
      await pref.flush()
    } catch (e) { /* ignore */ }
  }

  private handleSubmit(): void {
    const kw = this.keyword.trim()
    if (!kw) return
    this.submitted = kw
    this.saveHistory(kw)
    this.threads = []
    this.forums = []
    this.threadsDataSource.clear()
    this.forumsDataSource.clear()
    this.currentPage = 1
    this.doSearch(1)
  }

  private handleHistoryClick(kw: string): void {
    this.keyword = kw
    this.submitted = kw
    this.saveHistory(kw)
    this.threads = []
    this.forums = []
    this.threadsDataSource.clear()
    this.forumsDataSource.clear()
    this.currentPage = 1
    this.doSearch(1)
  }

  private async doSearch(page: number): Promise<void> {
    // 每次搜索开启新会话，旧搜索的过期回调将被丢弃
    const gen: number = this.scope.begin()
    if (page === 1) { this.isLoading = true } else { this.isLoadingMore = true }
    try {
      if (this.currentTab === 2) {
        const result: SearchForumResult = await searchForum(appStore.auth.token, this.submitted)
        if (!this.scope.isActive(gen)) {
          return
        }
        if (result.ok && result.data) {
          this.forums = result.data as object[]
          this.forumsDataSource.replaceAll(this.forums)
        }
      } else {
        const params: TopicListParams = createTopicListParams()
        params.page = String(page)
        if (this.currentTab === 1) params.searchpost = '1'
        if (this.currentTab === 3) { params.author = this.submitted } else { params.key = this.submitted }
        const result: TopicListResult = await getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords())
        if (!this.scope.isActive(gen)) {
          return
        }
        if (result.ok && result.data) {
          if (page === 1) {
            this.threads = result.data.threadPageList
            this.threadsDataSource.replaceAll(this.threads)
          } else {
            const arr: object[] = []
            for (let i = 0; i < this.threads.length; i++) { arr.push(this.threads[i]) }
            for (let i = 0; i < result.data.threadPageList.length; i++) { arr.push(result.data.threadPageList[i]) }
            this.threads = arr
            this.threadsDataSource.replaceAll(this.threads)
          }
          this.currentPage = page
          this.totalPages = result.data.pagination.totalPages
        }
      }
    } catch (e) { /* ignore */ }
    if (!this.scope.isActive(gen)) {
      return
    }
    this.isLoading = false
    this.isLoadingMore = false
    this.showEmpty = this.submitted.length > 0 && !this.isLoading && this.threads.length === 0 && this.forums.length === 0
  }

  private handleTabChange(index: number): void {
    if (this.currentTab === index) return
    this.currentTab = index
    this.threads = []
    this.forums = []
    this.threadsDataSource.clear()
    this.forumsDataSource.clear()
    this.currentPage = 1
    if (this.submitted) { this.doSearch(1) }
  }

  build() {
    Stack() {
      Column() {
        Row().width('100%').height(86 + this.statusBarHeight)

        if (this.submitted.length === 0) {
          if (this.history.length > 0) {
            Scroll() {
              Column() {
                Row() {
                  Text('搜索历史').fontSize(13).fontWeight(FontWeight.Bold).fontColor(AppColors.textSecondary)
                  Text('清空').fontSize(13).fontColor(AppColors.textTertiary).onClick(() => this.clearHistoryAll())
                }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.history, (kw: string) => {
                    Row() {
                      Text(escHtml(kw)).fontSize(14).fontColor(AppColors.textPrimary).onClick(() => this.handleHistoryClick(kw))
                      Text('✕').fontSize(12).fontColor(AppColors.textTertiary).margin({ left: 4 })
                        .onClick(() => this.removeHistory(kw))
                    }.padding({ left: 12, right: 10, top: 6, bottom: 6 })
                    .backgroundColor(AppColors.bgSecondary).borderRadius(16).margin({ right: 8, bottom: 8 })
                  })
                }
              }.width('100%').padding(16).alignItems(HorizontalAlign.Center)
            }.layoutWeight(1).align(Alignment.TopStart)
          } else {
            Column() {
              Image($r('app.media.icon_clock')).width(36).height(36).fillColor(AppColors.textTertiary).opacity(0.4)
              Text('暂无搜索历史').fontSize(14).fontColor(AppColors.textTertiary).margin({ top: 8 })
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          }
      } else if (this.isLoading) {
        Column() {
          LoadingProgress().width(28).height(28).color(AppColors.textTertiary)
          Text('搜索中...').fontSize(14).fontColor(AppColors.textTertiary).margin({ top: 8 })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else if (this.currentTab === 2) {
        if (this.forums.length === 0) {
          Column() { Text('#').fontSize(36).opacity(0.4); Text('未找到相关板块').fontSize(14).fontColor(AppColors.textTertiary).margin({ top: 8 }) }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List() {
            LazyForEach(this.forumsDataSource, (forum: object) => {
              ListItem() {
                Row() {
                  Image(`https://img4.nga.178.com/ngabbs/nga_classic/f/app/${(forum as Record<string, Object>)['fid']}.png`)
                    .width(40).height(40).borderRadius(10).objectFit(ImageFit.Cover).backgroundColor(AppColors.bgSecondary).margin({ right: 12 }).onError(() => {})
                  Column() {
                    Text(unescapeHtml(String((forum as Record<string, Object>)['name'] ?? ''))).fontSize(15).fontColor(AppColors.textPrimary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
                .onClick(() => {
                  const fid = Number((forum as Record<string, Object>)['fid'])
                  const name = String((forum as Record<string, Object>)['name'] ?? '')
                  routerStore.navigateForum(fid, name)
                })
              }
            }, (forum: object) => String((forum as Record<string, Object>)['fid'] ?? ''))
          }.width('100%').layoutWeight(1).divider({ strokeWidth: 0.5, color: AppColors.separator })
        }
      } else {
        if (this.threads.length === 0) {
          Column() { Image($r('app.media.icon_search')).width(36).height(36).fillColor(AppColors.textTertiary).opacity(0.4); Text('未找到相关结果').fontSize(14).fontColor(AppColors.textTertiary).margin({ top: 8 }) }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.threadsDataSource, (thread: object) => {
              ListItem() {
                this.SearchTopicCard(thread as Record<string, Object>)
              }
            }, (thread: object) => String((thread as Record<string, Object>)['tid'] ?? ''))
            ListItem() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (this.currentPage >= this.totalPages && this.threads.length > 0) {
                  Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                }
              }.width('100%').justifyContent(FlexAlign.Center).padding(16)
            }
          }.width('100%').layoutWeight(1).divider({ strokeWidth: 0.5, color: AppColors.separator })
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => { if (!this.isLoadingMore && this.currentPage < this.totalPages) { this.doSearch(this.currentPage + 1) } })
        }
      }
      }
      .width('100%').height('100%')

      Column() {
        Row() {
          Row() {
            Image($r('app.media.icon_search')).width(16).height(16).fillColor(AppColors.textTertiary).margin({ right: 8 })
            TextInput({ text: this.keyword, placeholder: '搜索板块、主题、内容...' })
              .layoutWeight(1).fontSize(15).backgroundColor(Color.Transparent).type(InputType.Normal)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .onChange((value: string) => { this.keyword = value })
              .onSubmit(() => this.handleSubmit())
            if (this.keyword.length > 0) {
              Text('✕').fontSize(16).fontColor(AppColors.textTertiary).margin({ left: 8 })
                .onClick(() => { this.keyword = ''; this.submitted = ''; this.threads = []; this.forums = []; this.threadsDataSource.clear(); this.forumsDataSource.clear() })
            }
          }.layoutWeight(1).height(40).padding({ left: 12, right: 12 })
          .backgroundColor(AppColors.bgSecondary).borderRadius(10).alignItems(VerticalAlign.Center)
          Text('取消').fontSize(15).fontColor(AppColors.primary).margin({ left: 12 }).onClick(() => routerStore.back())
        }.width('100%').padding({ left: 16, right: 16, top: 8 + this.statusBarHeight, bottom: 8 }).alignItems(VerticalAlign.Center)

        Row() {
          Text('主题').fontSize(14).fontColor(this.currentTab === 0 ? AppColors.primary : AppColors.textSecondary)
            .fontWeight(this.currentTab === 0 ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
            .onClick(() => this.handleTabChange(0))
          Text('内容').fontSize(14).fontColor(this.currentTab === 1 ? AppColors.primary : AppColors.textSecondary)
            .fontWeight(this.currentTab === 1 ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
            .onClick(() => this.handleTabChange(1))
          Text('板块').fontSize(14).fontColor(this.currentTab === 2 ? AppColors.primary : AppColors.textSecondary)
            .fontWeight(this.currentTab === 2 ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
            .onClick(() => this.handleTabChange(2))
          Text('作者').fontSize(14).fontColor(this.currentTab === 3 ? AppColors.primary : AppColors.textSecondary)
            .fontWeight(this.currentTab === 3 ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
            .onClick(() => this.handleTabChange(3))
        }.width('100%')
      }
      .width('100%')
      .backgroundColor(Color.Transparent)
      .backdropBlur(60)
      .border({ width: { bottom: 0.5 }, color: AppColors.separator })
      .position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }

  @Builder
  SearchTopicCard(thread: Record<string, Object>) {
    Column() {
      Row() {
        if (this.isAuthorBlacklisted(thread)) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .layoutWeight(1)
        } else {
          Text(this.getTypeTags(Number(thread['type'] ?? 0)))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
          Text(unescapeHtml(String(thread['subject'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(this.getSubjectFontColor(String(thread['titleFont'] ?? '')))
            .fontWeight(this.isSubjectBold(String(thread['titleFont'] ?? '')) ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(this.isSubjectItalic(String(thread['titleFont'] ?? '')) ? FontStyle.Italic : FontStyle.Normal)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
      }.width('100%').alignItems(VerticalAlign.Top)

      if (thread['previewSnippet']) {
        if (this.isPreviewAuthorBlacklisted(thread)) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .margin({ top: 6 })
            .width('100%')
        } else {
          Text(unescapeHtml(String(thread['previewSnippet'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textSecondary)
            .maxLines(2)
            .lineHeight(ReadingTypography.lineHeight(
              ReadingLineHeightRole.TOPIC_SUMMARY,
              ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize)
            ))
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 6 }).width('100%')
        }
      }

      Row() {
        Row() {
          AnonymousName({ author: String(thread['author'] ?? ''), isAnonymous: thread['isAnonymity'] as boolean, fontSize: 12 })
          if (appStore.settingsStore.getNote(String(thread['authorId'] ?? '')).length > 0) {
            Text('(' + appStore.settingsStore.getNote(String(thread['authorId'] ?? '')) + ')')
              .fontSize(11).fontColor(AppColors.warning).margin({ left: 3 })
          }
          Text(` · ${formatTime(Number(thread['postDate'] ?? 0))}`)
            .fontSize(12).fontColor(AppColors.textTertiary)
        }
        Row() { Image($r('app.media.icon_chat_bubble')).width(12).height(12).fillColor(AppColors.textTertiary); Text(` ${thread['replies'] ?? 0}`).fontSize(12).fontColor(AppColors.textTertiary) }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 8 })
    }
    .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).alignItems(HorizontalAlign.Start)
    .onClick(() => {
      const tid = String(thread['tid'] ?? '')
      if (tid) {
        routerStore.navigateActivity(Screen.thread(tid))
      }
    })
  }
}
