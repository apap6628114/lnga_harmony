/**
 * DOM 标记内容提取 — 从 NGA thread.php 主题列表页 HTML 中提取每行的展示字段。
 *
 * 主题行 DOM 结构（<tr class='topicrow'> 内 4 个 td）：
 *   c1: <a id='t_rc1_<n>' class='replies'>回帖数</a>
 *   c2: <a id='t_tt1_<n>' class='topic'>主题标题</a>
 *       <span id='t_pc1_<n>'></span>
 *       <span class='titleadd2'><a href='/thread.php?stid=...'>[版块名]</a></span>
 *       （回帖模式 searchpost=1 追加 topic_content：<span id='postcontent<tid>_<pid>'>回复正文</span>）
 *   c3: <a id='t_ta1_<n>' class='author' title='用户ID <uid>'>作者名</a>
 *       <span id='t_pt1_<n>' class='postdate'>发帖时间戳</span>
 *   c4: <a id='t_rt1_<n>' class='replydate'></a><span id='t_tr1_<n>' class='replyer'>最后回复者</span>
 *
 * 行号 <n> 与 topicArg.add 序号、JSON __T 索引键一一对应。
 * 正文/主题 span 的 id 由 tid 与 pid 组合（postcontent<tid>_<pid>），
 * 回复者 uid 从同名行的 commonui.postDispMini(...) 调用第 6 参提取。
 */

import { unescapeHtml } from '../../_shared/HtmlEntityCodec';
import { scanBalanced } from '../html-thread/ScanState';
import { splitTopLevelArgs } from '../html-thread/PostArgScanner';

const POSTDISP_MARKER: string = 'commonui.postDispMini(';

/**
 * 定位指定 id 的标签，返回标签结束（`>`）后的内容起点。
 *
 * @param html 源 HTML
 * @param idMarker 形如 `id='t_tt1_0'` 的定位标记
 * @returns 内容起点；未找到时返回 -1
 */
function locateTagContent(html: string, idMarker: string): number {
  const startIdx: number = html.indexOf(idMarker);
  if (startIdx < 0) {
    return -1;
  }
  const tagEnd: number = html.indexOf('>', startIdx);
  if (tagEnd < 0) {
    return -1;
  }
  return tagEnd + 1;
}

/**
 * 提取指定 id 标签到首个闭合标签之间的文本（剥内部 HTML 标签并反转实体）。
 *
 * @param html 源 HTML
 * @param idMarker 形如 `id='t_tt1_0'` 的定位标记
 * @param closeTag 闭合标签（如 `</a>`）
 * @returns 纯文本；未找到时返回空串
 */
function extractTagText(html: string, idMarker: string, closeTag: string): string {
  const contentStart: number = locateTagContent(html, idMarker);
  if (contentStart < 0) {
    return '';
  }
  const endIdx: number = html.indexOf(closeTag, contentStart);
  if (endIdx < 0) {
    return '';
  }
  const inner: string = html.substring(contentStart, endIdx);
  return unescapeHtml(inner.replace(/<[^>]+>/g, '')).trim();
}

/**
 * 提取主题标题（剥内部标签：普通标题无标签，「超过限制」条目标题含 span）。
 *
 * @param html 源 HTML
 * @param rowIndex 行号
 * @returns 主题标题；未找到时返回空串
 */
function extractTopicSubject(html: string, rowIndex: number): string {
  return extractTagText(html, `id='t_tt1_${rowIndex}'`, '</a>');
}

/**
 * 提取主题作者名。
 *
 * @param html 源 HTML
 * @param rowIndex 行号
 * @returns 作者名；未找到时返回空串
 */
function extractTopicAuthor(html: string, rowIndex: number): string {
  return extractTagText(html, `id='t_ta1_${rowIndex}'`, '</a>');
}

/**
 * 提取主题作者 uid（原样字符串，可能是数字或 `#anony_...` 匿名串）。
 *
 * 来源：作者链接 href `uid=...`（官方原始输出）或 title `用户ID ...`。
 * 搜索窗口从 `<a` 标签起点开始（href 位于 id 属性之前，需覆盖）。
 * JSON API 的 authorid 对匿名作者保留 `#anony_<32hex>` 字符串，需原样对齐。
 *
 * @param html 源 HTML
 * @param rowIndex 行号
 * @returns 作者 uid 字符串；无法解析时返回 '0'
 */
function extractTopicAuthorUid(html: string, rowIndex: number): string {
  const marker: string = `id='t_ta1_${rowIndex}'`;
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) {
    return '0';
  }
  const aStart: number = html.lastIndexOf('<a', startIdx);
  const segStart: number = aStart >= 0 ? aStart : startIdx;
  const seg: string = html.substring(segStart, startIdx + 200);
  const hrefMatch: RegExpMatchArray | null = seg.match(/uid=([^'"&<>\s]+)/);
  if (hrefMatch) {
    return hrefMatch[1];
  }
  const titleMatch: RegExpMatchArray | null = seg.match(/用户ID\s*([^\s'"]+)/);
  if (titleMatch) {
    return titleMatch[1];
  }
  return '0';
}

/**
 * 提取主题发帖时间戳（span 文本为秒级数字）。
 *
 * @param html 源 HTML
 * @param rowIndex 行号
 * @returns 发帖时间戳；未找到时返回 0
 */
function extractTopicPostDate(html: string, rowIndex: number): number {
  const text: string = extractTagText(html, `id='t_pt1_${rowIndex}'`, '</span>');
  const n: number = parseInt(text, 10);
  if (isNaN(n)) {
    return 0;
  }
  return n;
}

/**
 * 提取最后回复者名。
 *
 * @param html 源 HTML
 * @param rowIndex 行号
 * @returns 最后回复者名；未找到时返回空串
 */
function extractTopicReplier(html: string, rowIndex: number): string {
  return extractTagText(html, `id='t_tr1_${rowIndex}'`, '</span>');
}

/**
 * 提取回帖数。
 *
 * @param html 源 HTML
 * @param rowIndex 行号
 * @returns 回帖数；未找到时返回 0
 */
function extractTopicReplies(html: string, rowIndex: number): number {
  const text: string = extractTagText(html, `id='t_rc1_${rowIndex}'`, '</a>');
  const n: number = parseInt(text, 10);
  if (isNaN(n)) {
    return 0;
  }
  return n;
}

/**
 * 版块标记解析结果（titleadd2）。
 */
interface BoardMark {
  name: string;
  stid: number;
}

/**
 * 提取版块标记（titleadd2 紧随 t_pc1_<n> 之后）。
 *
 * DOM：`<span class='titleadd2'><a href='/thread.php?stid=<stid>' class='silver'>[版块名]</a></span>`
 * 或 fid 形式：`<a href='/thread.php?fid=<fid>'>[版块名]</a>`。
 * JSON parent 语义：{'0': fid, '1': stid, '2': 版块名}；「超过限制」等条目无 titleadd2。
 *
 * @param html 源 HTML
 * @param rowIndex 行号
 * @returns 版块标记；未找到时 name 为空、stid 为 0
 */
function extractTopicBoard(html: string, rowIndex: number): BoardMark {
  const result: BoardMark = { name: '', stid: 0 };
  const pcStart: number = locateTagContent(html, `id='t_pc1_${rowIndex}'`);
  if (pcStart < 0) {
    return result;
  }
  // titleadd2 与 t_pc1 同处 c2 <td> 内；段边界取下一个 </td>，避免跨行误匹配
  const tdEnd: number = html.indexOf('</td>', pcStart);
  if (tdEnd < 0) {
    return result;
  }
  const titleIdx: number = html.indexOf("class='titleadd2'", pcStart);
  if (titleIdx < 0 || titleIdx > tdEnd) {
    return result;
  }
  const spanEnd: number = html.indexOf('</span>', titleIdx);
  if (spanEnd < 0) {
    return result;
  }
  const seg: string = html.substring(titleIdx, spanEnd);
  const stidMatch: RegExpMatchArray | null = seg.match(/stid=(\d+)/);
  if (stidMatch) {
    result.stid = parseInt(stidMatch[1], 10);
  }
  const nameMatch: RegExpMatchArray | null = seg.match(/<a[^>]*>([\s\S]*?)<\/a>/);
  if (nameMatch) {
    result.name = unescapeHtml(nameMatch[1].replace(/<[^>]+>/g, '')).replace(/^\[|\]$/g, '').trim();
  }
  return result;
}

/**
 * 提取回帖正文（回帖模式 postcontent<tid>_<pid> span 内的 BBCode 原文）。
 *
 * 与 JSON __P.content 对齐：正文中的换行以 `<br/>` 文本形式保留（JSON 为
 * `\u003cbr/\u003e` 解码后的 `<br/>`），其余 HTML 标签剥除。
 *
 * @param html 源 HTML
 * @param tid 主题 id
 * @param pid 回复 pid
 * @returns 回复正文；未找到时返回空串
 */
function extractReplyContent(html: string, tid: number, pid: number): string {
  const marker: string = `id='postcontent${tid}_${pid}'`;
  const contentStart: number = locateTagContent(html, marker);
  if (contentStart < 0) {
    return '';
  }
  const endIdx: number = html.indexOf('</span>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  let text: string = html.substring(contentStart, endIdx);
  // 保护 <br> 变体为无尖括号占位符（避免被剥标签步骤误删），
  // 剥除其余标签后再还原为 JSON content 同形的 `<br/>` 文本
  text = text.replace(/<br\s*\/?>/gi, '__NGA_BR__');
  text = text.replace(/<[^>]+>/g, '');
  text = text.replace(/__NGA_BR__/g, '<br/>');
  return unescapeHtml(text).trim();
}

/**
 * 提取回帖主题（postsubject<tid>_<pid> span 文本；通常为空，与 JSON __P.subject 一致）。
 *
 * @param html 源 HTML
 * @param tid 主题 id
 * @param pid 回复 pid
 * @returns 回复主题；未找到时返回空串
 */
function extractReplySubject(html: string, tid: number, pid: number): string {
  return extractTagText(html, `id='postsubject${tid}_${pid}'`, '</span>');
}

/**
 * 回帖元数据（postDispMini 调用提取结果）。
 */
interface ReplyPostMeta {
  /** 回复者 uid（第 6 参） */
  authorid: number;
  /** 回复类型（第 7 参；与 JSON __P.type 同源） */
  type: number;
}

/**
 * 从 commonui.postDispMini(...) 调用提取回复者 uid 与回复类型（第 6/7 参）。
 *
 * 调用形态：postDispMini($('postsubject<tid>_<pid>'),$('postcontent<tid>_<pid>'),
 * 0,<tid>,<pid>,<authorid>,<type>)。按 tid/pid 匹配调用。
 *
 * @param html 源 HTML
 * @param tid 主题 id
 * @param pid 回复 pid
 * @returns 回复元数据；未找到匹配调用时 authorid/type 均为 0
 */
function extractReplyPostMeta(html: string, tid: number, pid: number): ReplyPostMeta {
  const result: ReplyPostMeta = { authorid: 0, type: 0 };
  let searchFrom: number = 0;
  while (true) {
    const startIdx: number = html.indexOf(POSTDISP_MARKER, searchFrom);
    if (startIdx < 0) {
      return result;
    }
    const openPos: number = startIdx + POSTDISP_MARKER.length - 1;
    const matched = scanBalanced(html, openPos, '(', ')');
    if (matched.value) {
      const argsStr: string = matched.value.substring(1, matched.value.length - 1);
      const args: string[] = splitTopLevelArgs(argsStr);
      if (args.length >= 7) {
        const callTid: number = parseInt(args[3], 10) || 0;
        const callPid: number = parseInt(args[4], 10) || 0;
        if (callTid === tid && callPid === pid) {
          result.authorid = parseInt(args[5], 10) || 0;
          result.type = parseInt(args[6], 10) || 0;
          return result;
        }
      }
    }
    searchFrom = startIdx + POSTDISP_MARKER.length;
  }
}

export {
  extractTopicSubject, extractTopicAuthor, extractTopicAuthorUid, extractTopicPostDate,
  extractTopicReplier, extractTopicReplies, extractTopicBoard,
  extractReplyContent, extractReplySubject, extractReplyPostMeta,
  BoardMark, ReplyPostMeta,
};
