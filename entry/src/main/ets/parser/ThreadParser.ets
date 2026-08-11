import type { ThreadData, ThreadRowInfo, Attachment, ThreadPagination } from '../model/Thread';

function hasKeywordMatch(content: string, keywords: string[]): boolean {
  for (let i = 0; i < keywords.length; i++) {
    if (content.includes(keywords[i])) {
      return true
    }
  }
  return false
}

export function parseThreadData(raw: object | null, blacklist: Set<string> = new Set(),
  keywords: string[] = [], noteMap: Record<string, string> = {}): ThreadData {
  const rowList: ThreadRowInfo[] = [];
  const rawObj = raw as Record<string, Object>;
  const dataObj = rawObj?.['data'] as Record<string, Object> | undefined;
  const rawRows = dataObj?.['__R'] as Record<string, Object> ?? {};
  const totalRows = Number(dataObj?.['__ROWS'] ?? 0);
  const rowsPerPage = Math.max(20, Number(dataObj?.['__R__ROWS_PAGE'] ?? 0));

  const keys = Object.keys(rawRows);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const r = rawRows[key] as Record<string, Object>;
    if (!r || r['pid'] === undefined || r['pid'] === null) continue;
    if (r['comment_to_id'] !== undefined && r['comment_to_id'] !== null &&
      r['content'] === undefined) continue;
    if (hasKeywordMatch(String(r['content'] ?? ''), keywords)) continue;
    rowList.push(mapRow(r, blacklist, keywords, noteMap));
  }

  const actualTotalRows: number = totalRows > 0 ? totalRows : rowList.length;
  const pagination: ThreadPagination = {
    page: 1,
    totalPages: Math.ceil(actualTotalRows / rowsPerPage),
    totalRows,
  };
  const result: ThreadData = {
    rowList,
    threadInfo: null,
    __F: (dataObj?.['__F'] ?? {}) as Record<string, string>,
    __ROWS: totalRows,
    rowNum: totalRows,
    pagination,
  };
  return result;
}

function mapRow(raw: Record<string, Object>, blacklist: Set<string>,
  keywords: string[] = [], noteMap: Record<string, string> = {}): ThreadRowInfo {
  const attachs: Attachment[] = [];
  const rawAttachs = raw['attachs'];
  if (rawAttachs && typeof rawAttachs === 'object') {
    const attachMap = rawAttachs as Record<string, Object>;
    const attachKeys = Object.keys(attachMap);
    for (let j = 0; j < attachKeys.length; j++) {
      const a = attachMap[attachKeys[j]] as Record<string, Object>;
      const att: Attachment = {
        aid: String(a['aid'] ?? ''),
        attachurl: String(a['attachurl'] ?? ''),
        url_utf8_org_name: String(a['url_utf8_org_name'] ?? ''),
        name: String(a['name'] ?? ''),
        ext: String(a['ext'] ?? ''),
        type: String(a['type'] ?? ''),
        size: Number(a['size']) || 0,
        thumb: Number(a['thumb']) || 0,
        dscp: String(a['dscp'] ?? ''),
        subid: Number(a['subid']) || 0,
      };
      attachs.push(att);
    }
  }

  const comments: ThreadRowInfo[] = [];
  const rawComments = raw['comment'];
  if (rawComments && typeof rawComments === 'object') {
    const commentMap = rawComments as Record<string, Object>;
    const commentKeys = Object.keys(commentMap);
    for (let j = 0; j < commentKeys.length; j++) {
      const c = commentMap[commentKeys[j]] as Record<string, Object>;
      if (!c || typeof c !== 'object') continue;
      if (hasKeywordMatch(String(c['content'] ?? ''), keywords)) continue;
      comments.push(mapRow(c, blacklist, keywords, noteMap));
    }
  }

  const hotReplies: ThreadRowInfo[] = [];
  const rawHotReply = raw['hotreply'];
  if (rawHotReply && typeof rawHotReply === 'object') {
    const hotReplyMap = rawHotReply as Record<string, Object>;
    const hotReplyKeys = Object.keys(hotReplyMap);
    for (let j = 0; j < hotReplyKeys.length; j++) {
      const h = hotReplyMap[hotReplyKeys[j]] as Record<string, Object>;
      if (!h || typeof h !== 'object') continue;
      if (hasKeywordMatch(String(h['content'] ?? ''), keywords)) continue;
      hotReplies.push(mapRow(h, blacklist, keywords, noteMap));
    }
  }

  const result: ThreadRowInfo = {
    tid: Number(raw['tid'] ?? 0),
    fid: Number(raw['fid'] ?? 0),
    pid: Number(raw['pid'] ?? 0),
    lou: Number(raw['lou'] ?? 0),
    authorid: Number(raw['authorid']) || 0,
    author: String(raw['author'] ?? ''),
    subject: String(raw['subject'] ?? ''),
    content: String(raw['content'] ?? ''),
    vote: String(raw['vote'] ?? ''),
    postdate: String(raw['postdate'] ?? ''),
    attachs,
    level: String(raw['level'] ?? ''),
    yz: String(raw['yz'] ?? ''),
    js_escap_avatar: String(raw['js_escap_avatar'] ?? ''),
    muteTime: String(raw['mute_time'] ?? ''),
    aurvrc: Number(raw['aurvrc'] ?? 0),
    signature: String(raw['signature'] ?? ''),
    comments,
    hotReplies,
    from_client: String(raw['from_client'] ?? ''),
    from_client_model: String(raw['from_client_model'] ?? ''),
    isanonymous: !!raw['isanonymous'],
    alterinfo: String(raw['alterinfo'] ?? ''),
    score: Number(raw['score'] ?? 0),
    score_2: Number(raw['score_2'] ?? 0),
    isInBlackList: blacklist.has(String(raw['authorid'])),
    userNote: noteMap[String(raw['authorid'])] ?? '',
    imageUrlList: (raw['imageUrlList'] as string[]) ?? [],
    formattedHtmlData: String(raw['formattedHtmlData'] ?? ''),
    postCount: String(raw['postCount'] ?? ''),
    reputation: Number(raw['reputation'] ?? 0),
    memberGroup: String(raw['memberGroup'] ?? ''),
  };
  return result;
}
