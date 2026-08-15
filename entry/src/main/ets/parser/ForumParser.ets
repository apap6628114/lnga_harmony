import type { Category, CategorySub, BoardContent, ForumSearchItem } from '../model/Forum';

/**
 * 解析版块搜索（forum.php?key=）响应为结构化条目。
 *
 * NGA compact JSON（__output=8）历史上存在两种形态：裸数组与
 * `{"data": [...]}` 包装；此处两种均兼容，字段缺失一律兜底，
 * 非法条目（无 name）直接过滤。
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
      return result;
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
