/**
 * NGA postArg 调用参数扫描 — 提取 commonui.postArg.proc / setAll / setDefault 调用的参数体。
 *
 * 包含：
 * - `splitTopLevelArgs`：在平衡括号内的字符串里按顶层逗号切分（保留各自原样）
 * - `parseAllPostArgs`：扫描所有 commonui.postArg.proc(...) 调用，解析为 PostArgData
 * - `extractUserInfo`：提取 commonui.userInfo.setAll(...) 的用户信息对象
 * - `extractTotalReplies`：从 setDefault 固定参数位提取总回复数
 * - `extractAlertInfo`：扫描 commonui.loadAlertInfo(...) 调用，提取楼层改动信息（alterinfo）
 *
 * `()` 参数体提取统一走 `scanBalanced`（见 ScanState.ets），调用方去除外层括号。
 */

import { extractBalancedBraces, scanBalanced } from './ScanState';
import { preprocessJson } from '../../NgaJsonSanitizer';

const PROC_MARKER: string = 'commonui.postArg.proc(';
const SETALL_MARKER: string = 'commonui.userInfo.setAll(';
const SETDEFAULT_MARKER: string = 'commonui.postArg.setDefault(';
const ALERT_MARKER: string = 'commonui.loadAlertInfo(';

/**
 * 单条 postArg.proc 调用解析后的结构化数据。
 */
interface PostArgData {
  lou: number;
  pid: number;
  type: number;
  authorid: string;
  postdatetimestamp: number;
  recommend: number;
  score: number;
  score_2: number;
  contentLength: number;
  fromClient: string;
  fromClientModel: string;
}

/**
 * 在已去除外层括号的参数体字符串中，按顶层逗号切分。
 *
 * 识别 `'` 与 `"` 字符串、`()` 与 `[]` 嵌套深度；仅在 depth===0 的逗号处切分。
 * `\` 转义下一字符。各片段做 trim。
 *
 * @param s 已去除外层括号的参数体（如 `0,'a',1,[...]`）
 * @returns 顶层参数片段数组
 */
function splitTopLevelArgs(s: string): string[] {
  const args: string[] = [];
  let depth: number = 0;
  let inString: boolean = false;
  let stringChar: string = '';
  let current: string = '';
  for (let i: number = 0; i < s.length; i++) {
    const ch: string = s[i];
    if (inString) {
      current += ch;
      if (ch === '\\') {
        i++;
        if (i < s.length) {
          current += s[i];
        }
      } else if (ch === stringChar) {
        inString = false;
      }
    } else if (ch === "'" || ch === '"') {
      current += ch;
      inString = true;
      stringChar = ch;
    } else if (ch === '(' || ch === '[') {
      current += ch;
      depth++;
    } else if (ch === ')' || ch === ']') {
      current += ch;
      depth--;
    } else if (ch === ',' && depth === 0) {
      args.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.trim().length > 0) {
    args.push(current.trim());
  }
  return args;
}

/**
 * 扫描 HTML 中所有 commonui.postArg.proc(...) 调用，解析为 lou → PostArgData 映射。
 *
 * 参数位置约定（共 ≥21 个）：[0]=lou, [10]=pid, [11]=type, [13]=authorid,
 * [14]=postdatetimestamp, [15]=score(逗号分隔 score_2,score), [16]=contentLength,
 * [19]=fromClient, [20]=fromClientModel。
 *
 * @param html NGA 帖子页 HTML
 * @returns lou 到 PostArgData 的映射
 */
function parseAllPostArgs(html: string): Map<number, PostArgData> {
  const result: Map<number, PostArgData> = new Map();
  let searchFrom: number = 0;
  while (true) {
    const startIdx: number = html.indexOf(PROC_MARKER, searchFrom);
    if (startIdx < 0) {
      break;
    }
    const openPos: number = startIdx + PROC_MARKER.length - 1;
    const matched = scanBalanced(html, openPos, '(', ')');
    if (!matched.value) {
      break;
    }
    const callArgsStr: string = matched.value.substring(1, matched.value.length - 1);
    const args: string[] = splitTopLevelArgs(callArgsStr);
    if (args.length >= 21) {
      const data: PostArgData = {
        lou: 0,
        pid: 0,
        type: 0,
        authorid: '',
        postdatetimestamp: 0,
        recommend: 0,
        score: 0,
        score_2: 0,
        contentLength: 0,
        fromClient: '',
        fromClientModel: '',
      };
      const louStr: string = stripQuotes(args[0].trim());
      if (!/^-?\d+$/.test(louStr)) {
        searchFrom = startIdx + PROC_MARKER.length;
        continue;
      }
      data.lou = parseInt(louStr, 10);
      const pidStr: string = args[10];
      data.pid = parseInt(pidStr, 10) || 0;
      const typeStr: string = args[11];
      data.type = parseInt(typeStr, 10) || 0;
      const aidStr: string = args[13];
      data.authorid = aidStr.replace(/'/g, '');
      const tsStr: string = args[14];
      data.postdatetimestamp = parseInt(tsStr, 10) || 0;
      const scoreStr: string = args[15];
      const scoreParts: string[] = scoreStr.replace(/'/g, '').split(',');
      data.recommend = parseInt(scoreParts[0], 10) || 0;
      data.score = parseInt(scoreParts[1], 10) || 0;
      data.score_2 = parseInt(scoreParts[2], 10) || 0;
      const clStr: string = args[16];
      data.contentLength = parseInt(clStr.replace(/'/g, ''), 10) || 0;
      const fcStr: string = args[19];
      data.fromClient = fcStr.replace(/'/g, '');
      if (args.length > 20) {
        const fcmStr: string = args[20];
        data.fromClientModel = fcmStr.replace(/'/g, '');
      }
      result.set(data.lou, data);
    }
    searchFrom = startIdx + PROC_MARKER.length;
  }
  return result;
}

/**
 * 提取 commonui.userInfo.setAll(...) 调用中的用户信息对象。
 *
 * @param html NGA 帖子页 HTML
 * @returns 用户信息对象；未找到或解析失败时返回空对象
 */
function extractUserInfo(html: string): Record<string, Object> {
  const idx: number = html.indexOf(SETALL_MARKER);
  if (idx < 0) {
    return {};
  }
  const jsonStr: string = extractBalancedBraces(html, idx + SETALL_MARKER.length);
  if (!jsonStr) {
    return {};
  }
  try {
    const cleaned: string = preprocessJson(jsonStr);
    const parsed: Object = JSON.parse(cleaned);
    if (typeof parsed === 'object' && parsed !== null) {
      return parsed as Record<string, Object>;
    }
  } catch (e) {
    return {};
  }
  return {};
}

/**
 * 从 commonui.postArg.setDefault(fid,stid,tid,tAid,topicMiscBit1,punUsers,visit,
 * mods,vote,customLevel,tType,totalReplies,lastPostTs,pageSize?) 提取总回复数。
 *
 * 网页 HTML 含最后的 pageSize，APP `__output=17 + __localres=1` 会省略它；
 * totalReplies 在两种形态中都固定为 index 11，不能按倒数位置解释。
 *
 * @param html NGA 帖子页 HTML
 * @returns 总回复数；未找到或参数不足时返回 -1
 */
function extractTotalReplies(html: string): number {
  const idx: number = html.indexOf(SETDEFAULT_MARKER);
  if (idx < 0) {
    return -1;
  }
  const openPos: number = idx + SETDEFAULT_MARKER.length - 1;
  const matched = scanBalanced(html, openPos, '(', ')');
  if (!matched.value) {
    return -1;
  }
  const argsStr: string = matched.value.substring(1, matched.value.length - 1);
  const args: string[] = splitTopLevelArgs(argsStr);
  if (args.length >= 13) {
    const val: string = args[11].trim();
    const n: number = parseInt(val, 10);
    if (!isNaN(n) && n >= 0) {
      return n;
    }
  }
  return -1;
}

/**
 * 从 commonui.postArg.setDefault(fid,stid,tid,tAid,topicMiscBit1,punUsers,visit,
 * mods,vote,customLevel,tType,totalReplies,lastPostTs,pageSize?) 提取全帖最后回复时间戳。
 *
 * lastPostTs 在网页与 APP HTML 中都固定为 index 12。跨页视图下页面内最后一楼
 * 的时间偏早，该字段与 JSON API `__T.lastpost` 同源。
 *
 * @param html NGA 帖子页 HTML
 * @returns 最后回复时间戳；未找到或参数不足时返回 0
 */
function extractLastPostTs(html: string): number {
  const idx: number = html.indexOf(SETDEFAULT_MARKER);
  if (idx < 0) {
    return 0;
  }
  const openPos: number = idx + SETDEFAULT_MARKER.length - 1;
  const matched = scanBalanced(html, openPos, '(', ')');
  if (!matched.value) {
    return 0;
  }
  const argsStr: string = matched.value.substring(1, matched.value.length - 1);
  const args: string[] = splitTopLevelArgs(argsStr);
  if (args.length >= 13) {
    const val: string = args[12].trim();
    const n: number = parseInt(val, 10);
    if (!isNaN(n) && n > 0) {
      return n;
    }
  }
  return 0;
}

/**
 * 去除 JS 字符串参数首尾的成对引号。
 *
 * @param s 原始参数片段（可能带 ' 或 " 包裹）
 * @returns 去引号后的内容
 */
function stripQuotes(s: string): string {
  const len: number = s.length;
  if (len >= 2 && ((s[0] === '"' && s[len - 1] === '"') || (s[0] === "'" && s[len - 1] === "'"))) {
    return s.substring(1, len - 1);
  }
  return s;
}

/**
 * 从 commonui.postArg.setDefault(fid,stid,tid,tAid,topicMiscBit1,punUsers,visit,mods,
 * vote,customLevel,tType,tReplies,tLastTime,thisPagePosts) 提取主题投票信息。
 *
 * 第 9 个参数（index 8）为 vote 字符串（与 JSON API 楼级 vote / __T.post_misc_var.vote
 * 同格式，实测投票帖 `208214~华为~...~max_select~1~end~<ts>~_208214~170,0,209~...`），
 * 非投票帖为 `""` 或空串。
 *
 * @param html NGA 帖子页 HTML
 * @returns 主题 vote 字符串；未找到或为空时返回 ''
 */
function extractSetDefaultVote(html: string): string {
  const idx: number = html.indexOf(SETDEFAULT_MARKER);
  if (idx < 0) {
    return '';
  }
  const openPos: number = idx + SETDEFAULT_MARKER.length - 1;
  const matched = scanBalanced(html, openPos, '(', ')');
  if (!matched.value) {
    return '';
  }
  const argsStr: string = matched.value.substring(1, matched.value.length - 1);
  const args: string[] = splitTopLevelArgs(argsStr);
  if (args.length < 9) {
    return '';
  }
  const vote: string = stripQuotes(args[8].trim());
  if (vote.length > 1) {
    return vote;
  }
  return '';
}

/**
 * 从 `commonui.loadAlertInfo(alterinfo, containerId)` 调用提取楼层改动信息。
 *
 * 页面为每个被编辑/被操作的楼层渲染
 * `<span id='alertc<lou>'></span><script>commonui.loadAlertInfo('[E<ts> 0 0]\t','alertc<lou>')</script>`，
 * 第一参数即 JSON API 的 `row.alterinfo` 原串（`[E...]` 编辑 / `[A...]` 加分 / `[L...]` /
 * `[U...]` 前缀，含尾随制表符），第二参数为容器 id `alertc<lou>`（lou 即页面楼层号）。
 * 无改动的楼层不渲染该调用。
 *
 * @param html NGA 帖子页 HTML
 * @returns 页面楼层号（alertc 容器号）到 alterinfo 原串的映射
 */
function extractAlertInfo(html: string): Map<number, string> {
  const result: Map<number, string> = new Map();
  let searchFrom: number = 0;
  while (true) {
    const startIdx: number = html.indexOf(ALERT_MARKER, searchFrom);
    if (startIdx < 0) {
      break;
    }
    const openPos: number = startIdx + ALERT_MARKER.length - 1;
    const matched = scanBalanced(html, openPos, '(', ')');
    if (!matched.value) {
      break;
    }
    const argsStr: string = matched.value.substring(1, matched.value.length - 1);
    const args: string[] = splitTopLevelArgs(argsStr);
    if (args.length >= 2) {
      const alterinfo: string = unescapeJsString(stripQuotes(args[0].trim()));
      const container: string = stripQuotes(args[1].trim());
      const louMatch: RegExpExecArray | null = /^alertc(\d+)$/.exec(container);
      if (louMatch && alterinfo.length > 0) {
        result.set(parseInt(louMatch[1], 10), alterinfo);
      }
    }
    searchFrom = startIdx + ALERT_MARKER.length;
  }
  return result;
}

/**
 * 还原 JS 字符串字面量中的常见转义（`\\`、`\'`、`\"`、`\t`、`\n`、`\r`）。
 *
 * alterinfo 由服务端生成（`[E<ts> 0 0]\t` 形态），正常不含引号，但页面 JS 转义
 * 可能引入 `\'`/`\\`，此处保守还原以避免污染提交/展示。
 *
 * @param s 原始字符串（已去外层引号）
 * @returns 还原转义后的字符串
 */
function unescapeJsString(s: string): string {
  let result: string = '';
  for (let i: number = 0; i < s.length; i++) {
    const ch: string = s[i];
    if (ch === '\\' && i + 1 < s.length) {
      const next: string = s[i + 1];
      if (next === '\\' || next === "'" || next === '"') {
        result += next;
        i++;
      } else if (next === 't') {
        result += '\t';
        i++;
      } else if (next === 'n') {
        result += '\n';
        i++;
      } else if (next === 'r') {
        result += '\r';
        i++;
      } else {
        result += ch;
      }
    } else {
      result += ch;
    }
  }
  return result;
}

export { PostArgData, splitTopLevelArgs, parseAllPostArgs, extractUserInfo, extractTotalReplies, extractLastPostTs, extractSetDefaultVote, extractAlertInfo };
