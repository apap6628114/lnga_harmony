/**
 * NGA postArg 调用参数扫描 — 提取 commonui.postArg.proc / setAll / setDefault 调用的参数体。
 *
 * 包含：
 * - `splitTopLevelArgs`：在平衡括号内的字符串里按顶层逗号切分（保留各自原样）
 * - `parseAllPostArgs`：扫描所有 commonui.postArg.proc(...) 调用，解析为 PostArgData
 * - `extractUserInfo`：提取 commonui.userInfo.setAll(...) 的用户信息对象
 * - `extractTotalReplies`：从 setDefault 倒数第三个参数提取总回复数
 *
 * `()` 参数体提取统一走 `scanBalanced`（见 ScanState.ets），调用方去除外层括号。
 */

import { extractBalancedBraces, scanBalanced } from './ScanState';
import { preprocessJson } from '../../NgaJsonSanitizer';

const PROC_MARKER: string = 'commonui.postArg.proc(';
const SETALL_MARKER: string = 'commonui.userInfo.setAll(';
const SETDEFAULT_MARKER: string = 'commonui.postArg.setDefault(';

/**
 * 单条 postArg.proc 调用解析后的结构化数据。
 */
interface PostArgData {
  lou: number;
  pid: number;
  type: number;
  authorid: string;
  postdatetimestamp: number;
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
        score: 0,
        score_2: 0,
        contentLength: 0,
        fromClient: '',
        fromClientModel: '',
      };
      const louStr: string = args[0];
      data.lou = parseInt(louStr, 10) || 0;
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
      data.score_2 = parseInt(scoreParts[0], 10) || 0;
      data.score = parseInt(scoreParts[1], 10) || 0;
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
 * 从 commonui.postArg.setDefault(fid,stid,tid,...,totalReplies,lastPostTs,pageSize) 提取总回复数。
 *
 * 倒数第 3 个参数 = 全楼总回复数，倒数第 1 个 = 每页帖子数。
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
  // 参数格式固定：fid,stid,tid,...,totalReplies,lastPostTs,postsPerPage
  // 倒数第 3 个 = totalReplies, 倒数第 1 个 = postsPerPage(校验用)
  if (args.length >= 3) {
    const val: string = args[args.length - 3].trim();
    const n: number = parseInt(val, 10);
    if (!isNaN(n) && n >= 0) {
      return n;
    }
  }
  return -1;
}

/**
 * 从 commonui.postArg.setDefault(fid,stid,tid,...,totalReplies,lastPostTs,pageSize) 提取全帖最后回复时间戳。
 *
 * 倒数第 2 个参数 = 全帖最后回复时间戳（跨页视图下页面内最后一楼的时间偏早，
 * 与 JSON API `__T.lastpost` 同源，实测两样本逐位一致）。
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
  // 参数格式固定：fid,stid,tid,...,totalReplies,lastPostTs,postsPerPage
  // 倒数第 2 个 = lastPostTs
  if (args.length >= 2) {
    const val: string = args[args.length - 2].trim();
    const n: number = parseInt(val, 10);
    if (!isNaN(n) && n > 0) {
      return n;
    }
  }
  return 0;
}

export { PostArgData, splitTopLevelArgs, parseAllPostArgs, extractUserInfo, extractTotalReplies, extractLastPostTs };
