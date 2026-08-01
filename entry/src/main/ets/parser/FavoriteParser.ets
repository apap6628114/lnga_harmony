import { FavoriteTopicFolder } from '../model/Favorite'

/**
 * 从 NGA JSON 响应中读取 data 对象。
 *
 * @param raw - NGA 客户端返回的完整响应
 * @returns data 对象；缺失时返回空对象
 */
export function getFavoriteResponseData(raw: object): Record<string, Object> {
  const response: Record<string, Object> = raw as Record<string, Object>
  const data: Object | undefined = response['data']
  if (data !== undefined && data !== null && typeof data === 'object' && !Array.isArray(data)) {
    return data as Record<string, Object>
  }
  return {}
}

/**
 * 将 NGA `topic_favor_v2/list_folder` 响应转换为收藏夹列表。
 *
 * @param raw - NGA 客户端返回的完整响应
 * @returns 默认收藏夹优先排列的收藏夹列表
 */
export function parseFavoriteTopicFolders(raw: object): FavoriteTopicFolder[] {
  const data: Record<string, Object> = getFavoriteResponseData(raw)
  const folderContainer: Object | undefined = data['0']
  if (folderContainer === undefined || folderContainer === null ||
    typeof folderContainer !== 'object' || Array.isArray(folderContainer)) {
    return []
  }

  const record: Record<string, Object> = folderContainer as Record<string, Object>
  const keys: string[] = Object.keys(record)
  const folders: FavoriteTopicFolder[] = []
  for (let i = 0; i < keys.length; i++) {
    const entry: Object = record[keys[i]]
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      continue
    }
    const item: Record<string, Object> = entry as Record<string, Object>
    const folder: FavoriteTopicFolder = new FavoriteTopicFolder()
    folder.id = String(item['id'] ?? keys[i])
    folder.name = String(item['name'] ?? '')
    const parsedTopicCount: number = Number(item['length'] ?? 0)
    folder.topicCount = Number.isFinite(parsedTopicCount) ? Math.max(0, parsedTopicCount) : 0
    folder.isDefault = Object.keys(item).includes('default')
    if (folder.id.length > 0) {
      folders.push(folder)
    }
  }
  folders.sort((left: FavoriteTopicFolder, right: FavoriteTopicFolder): number => {
    if (left.isDefault === right.isDefault) {
      return 0
    }
    return left.isDefault ? -1 : 1
  })
  return folders
}
