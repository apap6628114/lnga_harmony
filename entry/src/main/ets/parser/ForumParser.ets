import type { Category, CategorySub, BoardContent, ForumSearchItem } from '../model/Forum';

/**
 * 解析版块搜索响应为结构化条目。
 *
 * NGA compact JSON（__output=8）历史上存在两种形态：裸数组与
 * `{"data": [...]}` 包装；官方 APP 签名通道（app_api.php forum/search，
 * __output=14）返回 `{"code":0,"result":[...]}` 的 result 数组。
 * 三种形态均兼容，字段缺失一律兜底，非法条目（无 name）直接过滤。
 *
 * @param raw - 版块搜索响应
 * @returns 结构化版块条目列表
 */
export function parseForumSearch(raw: object | null): ForumSearchItem[] {
  const result: ForumSearchItem[] = [];
  if (!raw) return result;

  let list: Object | undefined;
  if (Array.isArray(raw)) {
    list = raw;
  } else {
    const rawObj = raw as Record<string, Object>;
    const data = rawObj['data'];
    if (Array.isArray(data)) {
      list = data;
    } else {
      const appResult = rawObj['result'];
      if (Array.isArray(appResult)) {
        list = appResult;
      } else {
        return result;
      }
    }
  }

  const arr = list as Array<Object>;
  for (let i = 0; i < arr.length; i++) {
    const item = arr[i] as Record<string, Object>;
    const name = String(item['name'] ?? '');
    if (name.length === 0) continue;
    result.push({
      fid: String(item['fid'] ?? ''),
      stid: String(item['stid'] ?? item['id'] ?? ''),
      name: name,
      info: String(item['info'] ?? ''),
    });
  }
  return result;
}

/**
 * 解析版块分类树响应为结构化分类列表。
 *
 * 兼容两种 result 形状：
 *  - 官方 APP 签名通道（app_api.php home/category，__output=14）：result 为
 *    **数组**（实测 7 个分类），元素 {id, _id, name, groups:[{name, id, info,
 *    forums:[{fid, name, bit, is_forumlist, id, icon, info, nameS}]}]}；
 *    分类标识用 _id（实测各分类 id 恒为 0）
 *  - 旧网页版通道：result 为数字键对象（Object.keys 遍历）
 *
 * 数组在 Object.keys 下返回索引字符串，两种形状共用同一数字键遍历。
 *
 * @param raw - 版块分类响应
 * @returns 结构化分类列表
 */
export function parseForumCategories(raw: object | null): Category[] {
  const categories: Category[] = [];
  if (!raw) return categories;

  const rawObj = raw as Record<string, Object>;
  const result = rawObj['result'];
  if (!result || typeof result !== 'object') return categories;

  const resultRecord = result as Record<string, Object>;
  const keys = Object.keys(resultRecord);
  for (let i = 0; i < keys.length; i++) {
    const cat = resultRecord[keys[i]] as Record<string, Object>;
    const category: Category = {
      id: String(cat['_id'] ?? cat['id'] ?? ''),
      name: String(cat['name'] ?? ''),
      sub: parseGroups(cat['groups']),
    };
    categories.push(category);
  }
  return categories;
}

function parseGroups(groups: Object | undefined): CategorySub[] {
  const result: CategorySub[] = [];
  if (!Array.isArray(groups)) return result;

  const arr = groups as Array<Object>;
  for (let i = 0; i < arr.length; i++) {
    const g = arr[i] as Record<string, Object>;
    const sub: CategorySub = {
      name: String(g['name'] ?? ''),
      content: parseForums(g['forums']),
    };
    result.push(sub);
  }
  return result;
}

function parseForums(forums: Object | undefined): BoardContent[] {
  const result: BoardContent[] = [];
  if (!Array.isArray(forums)) return result;

  const arr = forums as Array<Object>;
  for (let i = 0; i < arr.length; i++) {
    const f = arr[i] as Record<string, Object>;
    const board: BoardContent = {
      fid: Number(f['fid']) || 0,
      stid: Number(f['id']) || 0,
      name: String(f['name'] ?? ''),
      info: String(f['info'] ?? ''),
      nameS: String(f['name'] ?? ''),
      infoS: String(f['info'] ?? ''),
      head: String(f['icon'] ?? ''),
      bit: f['bit'] as number | undefined,
    };
    result.push(board);
  }
  return result;
}
