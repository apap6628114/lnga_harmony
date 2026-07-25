import { type NavEntry } from '../store/RouterStore'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { ThreadPanel } from './ThreadPanel'
import { ProfilePanel } from './ProfilePanel'
import { NotificationPanel } from './NotificationPanel'
import { MessageListPanel } from './MessageListPanel'
import { MessageDetailPanel } from './MessageDetailPanel'
import { BlacklistPanel } from './BlacklistPanel'
import { NotesPanel } from './NotesPanel'
import { FilterKeywordsPanel } from './FilterKeywordsPanel'
import { SettingsPanel } from './SettingsPanel'
import { TtsSettingsPanel } from './TtsSettingsPanel'
import { BrowseHistoryPanel } from './BrowseHistoryPanel'
import { TopicListPanel } from './TopicListPanel'
import { WebViewPanel } from './WebViewPanel'
import { AiSettingsPanel } from './ai/AiSettingsPanel'
import { FontSizeSettingsPanel } from './FontSizeSettingsPanel'
import { TtsPlayer } from '../common/media/TtsPlayer'

@Component
export struct ActivityRouter {
  @Prop @Watch('onActivityStackChanged') activityStack: NavEntry[] = []
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 当前位于活动栈顶部的帖子条目标识。 */
  private activeThreadEntryId: number = -1

  /**
   * 记录组件首次显示时的顶层帖子条目。
   */
  aboutToAppear(): void {
    this.activeThreadEntryId = this.resolveActiveThreadEntryId()
  }

  /**
   * 在顶层帖子被关闭、替换或覆盖时停止帖子朗读。
   */
  private onActivityStackChanged(): void {
    const nextThreadEntryId: number = this.resolveActiveThreadEntryId()
    if (this.activeThreadEntryId >= 0 && nextThreadEntryId !== this.activeThreadEntryId) {
      TtsPlayer.stop()
    }
    this.activeThreadEntryId = nextThreadEntryId
  }

  /**
   * 获取当前位于活动栈顶部的帖子条目标识。
   *
   * @returns 顶层是帖子时返回条目标识，否则返回 -1。
   */
  private resolveActiveThreadEntryId(): number {
    if (this.activityStack.length === 0) {
      return -1
    }
    const topEntry: NavEntry = this.activityStack[this.activityStack.length - 1]
    return topEntry.screen.type === 'thread' ? topEntry.id : -1
  }

  build() {
    Stack() {
      ForEach(this.activityStack, (entry: NavEntry) => {
        Column() {
          if (entry.screen.type === 'thread') {
            ThreadPanel({
              threadTid: entry.screen.tid,
              threadPid: entry.screen.pid,
              navEntryId: entry.id
            })
          } else if (entry.screen.type === 'browseHistory') {
            BrowseHistoryPanel()
          } else if (entry.screen.type === 'messages') {
            MessageListPanel({ composeToInit: entry.screen.composeTo })
          } else if (entry.screen.type === 'notifications') {
            NotificationPanel()
          } else if (entry.screen.type === 'blacklist') {
            BlacklistPanel()
          } else if (entry.screen.type === 'notes') {
            NotesPanel()
          } else if (entry.screen.type === 'filterKeywords') {
            FilterKeywordsPanel()
          } else if (entry.screen.type === 'topicList') {
            TopicListPanel({
              boardFid: entry.screen.topicListFid,
              boardName: entry.screen.topicListName,
              isFavorites: entry.screen.topicListFavor === '1',
              authorid: entry.screen.topicListAuthorid,
              favor: entry.screen.topicListFavor,
              searchpost: entry.screen.topicListSearchpost
            })
          } else if (entry.screen.type === 'profile') {
            ProfilePanel({ uid: entry.screen.uid })
          } else if (entry.screen.type === 'ttsSettings') {
            TtsSettingsPanel()
          } else if (entry.screen.type === 'settings') {
            SettingsPanel()
          } else if (entry.screen.type === 'aiSettings') {
            AiSettingsPanel()
          } else if (entry.screen.type === 'fontSizeSettings') {
            FontSizeSettingsPanel()
          } else if (entry.screen.type === 'webview') {
            WebViewPanel({ url: entry.screen.webviewUrl })
          } else {
            Stack() {
              Column() {
                Row().width('100%').height(44 + this.statusBarHeight)
                Column() {
                  this.ContentBody(entry)
                }
                .layoutWeight(1).width('100%')
              }
              .width('100%').height('100%')

              PanelNavBar({ title: entry.screen.getTitle() })
                .width('100%').position({ x: 0, y: 0 })
            }
            .width('100%').height('100%')
          }
        }
        .width('100%').height('100%')
        .id(`activity_entry_${entry.id}`) // 【关键】给组件赋予唯一 ID，确保离场节点能保留并播放动画
        .transition(
          TransitionEffect.asymmetric(
            // 进场动画
            TransitionEffect.move(TransitionEdge.END)
              .combine(TransitionEffect.OPACITY)
              .animation({ duration: 450, curve: Curve.FastOutSlowIn }),
            // 退场动画
            TransitionEffect.move(TransitionEdge.END)
              .combine(TransitionEffect.OPACITY)
              .animation({ duration: 450, curve: Curve.FastOutSlowIn })
          )
        )
      }, (entry: NavEntry) => String(entry.id))
    }
    .width('100%').height('100%')
  }

  @Builder
  ContentBody(entry: NavEntry) {
    if (entry.screen.type === 'messageDetail') {
      MessageDetailPanel({ mid: entry.screen.mid })
    } else {
      Column() {
        Text('未知页面类型').fontSize(14).fontColor(AppColors.textTertiary)
      }
      .layoutWeight(1).width('100%')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    }
  }
}
