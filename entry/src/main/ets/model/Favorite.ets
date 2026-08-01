/**
 * NGA 主题收藏夹领域模型。
 */

/**
 * 主题收藏操作。
 */
export enum TopicFavoriteOperation {
  /**
   * 将主题加入指定收藏夹。
   */
  ADD = 'add',
  /**
   * 将主题从指定收藏夹移除。
   */
  DELETE = 'del'
}

/**
 * 主题与收藏夹关系的本地可信状态。
 */
export enum FavoriteMembershipState {
  /**
   * 当前客户端没有足够信息判断。
   */
  UNKNOWN = 'unknown',
  /**
   * 已确认主题位于收藏夹中。
   */
  FAVORED = 'favored',
  /**
   * 已确认主题不位于收藏夹中。
   */
  NOT_FAVORED = 'not_favored'
}

/**
 * NGA 服务端主题收藏夹。
 */
export class FavoriteTopicFolder {
  /**
   * 收藏夹服务端 ID。
   */
  id: string = ''
  /**
   * 收藏夹名称。
   */
  name: string = ''
  /**
   * 收藏夹内主题数量。
   */
  topicCount: number = 0
  /**
   * 是否为账号默认收藏夹。
   */
  isDefault: boolean = false
}
