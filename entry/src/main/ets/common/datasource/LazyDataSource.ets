import type { PostInfo } from '../../model/PostInfo'
import type { MessageThreadInfo, MessageArticle } from '../../model/Message'
import type { NotificationInfo } from '../../model/Notification'
import type { BlacklistEntry } from '../../model/SocialEntries'
import type { FilterKeyword } from '../../model/FilterKeyword'
import type { UserNoteEntry } from '../../model/NoteInfo'
import type { Category, BoardContent } from '../../model/Forum'
import type { FollowedActivity, FollowedUser } from '../../model/Follow'
import { BaseLazyDataSource } from './BaseLazyDataSource'

/** 主题帖子列表数据源，复用基类全部共性逻辑。 */
class PostInfoDataSource extends BaseLazyDataSource<PostInfo> {
}

/** 主题列表数据源。 */
class ThreadDataSource extends BaseLazyDataSource<object> {
}

/** 私信会话列表数据源。 */
class MessageThreadDataSource extends BaseLazyDataSource<MessageThreadInfo> {
}

/** 私信内容列表数据源。 */
class MessageArticleDataSource extends BaseLazyDataSource<MessageArticle> {
}

/** 通知列表数据源。 */
class NotificationDataSource extends BaseLazyDataSource<NotificationInfo> {
}

/** 黑名单列表数据源。 */
class BlacklistDataSource extends BaseLazyDataSource<BlacklistEntry> {
}

interface SidebarBoardItem {
  fid: number;
  stid: number;
  name: string;
}

interface SidebarSection {
  id: string;
  name: string;
  items: SidebarBoardItem[];
  collapsed: boolean;
  collapsible: boolean;
}

/**
 * 侧边栏分区数据源。
 * 在基类共性逻辑之外，额外提供按 section id 查询下标、
 * 覆写单个分区并触发数据变更通知。
 */
class SidebarDataSource extends BaseLazyDataSource<SidebarSection> {
  /**
   * 覆写指定下标的分区并触发该位置的数据变更通知。
   *
   * @param index - 目标下标
   * @param section - 新分区
   */
  updateSection(index: number, section: SidebarSection): void {
    this.dataList[index] = section
    this.notifyDataChange(index)
  }

  /**
   * 按 section id 查找下标，未命中返回 -1。
   *
   * @param sectionId - 分区 id
   * @returns 分区下标，未找到为 -1
   */
  indexOf(sectionId: string): number {
    for (let i = 0; i < this.dataList.length; i++) {
      if (this.dataList[i].id === sectionId) {
        return i
      }
    }
    return -1
  }
}

/** 论坛分类列表数据源。 */
class CategoryDataSource extends BaseLazyDataSource<Category> {
}

/** 浏览历史列表数据源。 */
class HistoryItemDataSource extends BaseLazyDataSource<object> {
}

/** 用户备注列表数据源。 */
class NotesDataSource extends BaseLazyDataSource<UserNoteEntry> {
}

/** 过滤关键词列表数据源。 */
class FilterKeywordDataSource extends BaseLazyDataSource<FilterKeyword> {
}

/** 关注动态列表数据源。 */
class FollowedActivityDataSource extends BaseLazyDataSource<FollowedActivity> {
}

/** 关注/粉丝用户列表数据源。 */
class FollowedUserDataSource extends BaseLazyDataSource<FollowedUser> {
}

export {
  PostInfoDataSource, ThreadDataSource, MessageThreadDataSource,
  MessageArticleDataSource, NotificationDataSource, BlacklistDataSource,
  NotesDataSource, FilterKeywordDataSource, CategoryDataSource,
  HistoryItemDataSource, SidebarDataSource, SidebarSection, SidebarBoardItem,
  FollowedActivityDataSource, FollowedUserDataSource
}
