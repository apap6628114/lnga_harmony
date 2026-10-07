/**
 * NGA postArg 调用参数扫描 — 提取 commonui.postArg.proc / setAll / setDefault 调用的参数体。
 *
 * 包含：
 * - `splitTopLevelArgs`：在平衡括号内的字符串里按顶层逗号切分（保留各自原样）
 * - `parseAllPostArgs`：扫描所有 commonui.postArg.proc(...) 调用，解析为 PostArgData
 * - `extractUserInfo`：提取 commonui.userInfo.setAll(...) 的用户信息对象
 * - `extractTotalReplies`：从 setDefault 固定参数位提取总回复数
 * - `extractAlertInfo`：扫描 commonui.loadAlertInfo(...) 调用，提取楼层改动信息（alterinfo）
 * - `extractPostAuthorKey`：uid 原串 + 用户表 → 跨页可比的稳定作者标识（匿名 `#anony_` 编码名）
 * - `extractTopicAuthorKey`：主题作者（楼主）的稳定作者标识；判不出返回空串，绝不猜首楼作者
 *
 * `()` 参数体提取统一走 `scanBalanced`（见 ScanState.ets），调用方去除外层括号。
 */

import { extractBalancedBraces, scanBalanced } from './ScanState';
import { preprocessJson } from '../../NgaJsonSanitizer';
import { ANONYMOUS_NAME_PREFIX } from '../../AnonymousParser';

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
 * 解析单个楼层的**稳定作者标识** `authorKey`（跨页可比）。
 *
 * 用途是「楼主」标记这类跨楼层身份比较。NGA 匿名楼层的 `postArg.proc` 第 13 参给的是
 * **页内局部**合成 uid（`-1`、`-2`…，每页按楼层出现顺序重新分配，同一匿名用户在第二页
 * 可能是另一个负数，而主题作者 tAid 又是另一个局部号），拿它跨页比较必然错位——
 * 楼主自己的匿名回复认不出，别的匿名用户又可能因撞上同一个局部号被误标成楼主。
 * 同一匿名用户真正稳定的身份是 `__U` 用户表里的 `username`（`#anony_<32 位十六进制>`，
 * 同一帖子内稳定）。故：
 * - 匿名楼层 → 返回 `#anony_` 编码名（稳定、可跨页比较）
 * - 普通楼层 → 返回 uid 数字串
 *
 * 楼层元数据（`row.authorid`）保持数字语义不变，只有本字段承担身份比较职责。
 *
 * @param userInfo 用户信息表（uid → 用户对象，匿名条目在表内 uid 字段为 0）
 * @param authoridStr `postArg.proc` 的 uid 原串（匿名时为页内局部负数）
 * @returns 稳定作者标识；无法判定时返回空串
 */
function extractPostAuthorKey(userInfo: Record<string, Object>, authoridStr: string): string {
  const uidStr: string = authoridStr.replace(/'/g, '').trim();
  const user: Record<string, Object> | undefined = userInfo[uidStr] as Record<string, Object> | undefined;
  const username: string = user && user['username'] !== undefined ? String(user['username']) : '';
  if (username.startsWith(ANONYMOUS_NAME_PREFIX)) {
    return username;
  }
  if (uidStr.startsWith(ANONYMOUS_NAME_PREFIX)) {
    return uidStr;
  }
  const uid: number = parseInt(uidStr, 10);
  return isNaN(uid) ? '' : String(uid);
}

/**
 * 从 commonui.postArg.setDefault(fid,stid,tid,tAid,topicMiscBit1,punUsers,visit,
 * mods,vote,customLevel,tType,totalReplies,lastPostTs,pageSize?) 提取主题作者 ID。
 *
 * tAid 固定为 index 3（与 JSON API `__T.authorid` 同源）。跨页视图下楼主不在
 * 当前页楼层中，页面仅凭 setDefault 的 tAid 提供主题作者；当前页楼层首楼的
 * authorid 不能代表主题作者。
 *
 * @param html NGA 帖子页 HTML
 * @returns 主题作者 ID；未找到或参数不足时返回 0
 */
function extractTopicAuthorId(html: string): number {
  const val: string = extractTopicAuthorIdRaw(html);
  const n: number = parseInt(val, 10);
  if (!isNaN(n) && n > 0) {
    return n;
  }
  return 0;
}

/**
 * 从 setDefault 提取 tAid 的原串（不清洗为数字）。
 *
 * tAid 与 JSON API `__T.authorid` 同源：普通帖是真实 uid，匿名帖是**页内局部**负数
 * （实测 tid=46151001 为 `-4`，而楼主楼层用的是 `-1`/`-2`/`-3`，即 tAid 与楼层局部号
 * 并不相等）。因此它只能用来定位 `__U` 用户表条目，不能直接当身份比较。
 *
 * @param html NGA 帖子页 HTML
 * @returns tAid 原串；未找到或参数不足时返回空串
 */
function extractTopicAuthorIdRaw(html: string): string {
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
  if (args.length >= 4) {
    return args[3].trim();
  }
  return '';
}

/**
 * 解析主题作者（楼主）的稳定作者标识 `topicAuthorKey`，跨页可用。
 *
 * 判据按"可信度"分两级，**判不出就返回空串（未知），绝不猜**：
 * 1. 本页含主楼（lou=0）→ 取主楼楼的 `authorKey`（同页主楼与楼主必然同人）。普通帖得
 *    uid 数字串；匿名帖得 `#anony_` 编码名（跨页稳定）。
 * 2. 本页不含主楼（只看楼主 / 定位到非首页）→ 只信 setDefault 的 tAid 且**必须命中
 *    `__U` 里的正数 uid 条目**（普通帖的楼主 uid 与 JSON `__T.authorid` 同源，跨页有效）。
 *    匿名帖这一级一律不采用：实测（tid=46151001、47680877、47679674）非首页的 tAid 与
 *    楼层 uid 是**两套页内局部负数**，且页面常常完全没有 `#anony_`/负键条目——拿局部号
 *    去 `__U` 里撞，撞到的可能是**另一个匿名用户**，正好会把陌生人标成楼主。
 *
 * 返回空串时客户端会跳过「楼主」标记（少标而不是标错人）；一旦读到含主楼的页，
 * 标记随之恢复。
 *
 * @param userInfo 用户信息表（uid → 用户对象）
 * @param topicAuthorIdRaw setDefault 的 tAid 原串；空串表示页面未提供
 * @param hasMainFloor 当前页是否含主楼（lou=0）
 * @param mainFloorKey 主楼楼的 `authorKey`（`hasMainFloor` 为 true 时有效）
 * @returns 稳定作者标识；无法可靠判定时返回空串（未知）
 */
function extractTopicAuthorKey(userInfo: Record<string, Object>, topicAuthorIdRaw: string,
  hasMainFloor: boolean, mainFloorKey: string): string {
  if (hasMainFloor && mainFloorKey.length > 0) {
    return mainFloorKey;
  }
  if (topicAuthorIdRaw) {
    const user: Record<string, Object> | undefined = userInfo[topicAuthorIdRaw] as Record<string, Object> | undefined;
    if (user) {
      const key: string = extractPostAuthorKey(userInfo, topicAuthorIdRaw);
      // 只接受真实 uid：匿名编码名与页内局部负数都不能当跨页身份
      if (key.length > 0 && !key.startsWith(ANONYMOUS_NAME_PREFIX) && Number(key) > 0) {
        return key;
      }
    }
  }
  return '';
}

/**
 * 从 commonui.postArg.setDefault(fid,stid,tid,tAid,topicMiscBit1,punUsers,visit,
 * mods,vote,customLevel,tType,totalReplies,lastPostTs,pageSize?) 提取主题投票信息。
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

export { PostArgData, splitTopLevelArgs, parseAllPostArgs, extractUserInfo, extractTotalReplies, extractTopicAuthorId, extractTopicAuthorIdRaw, extractLastPostTs, extractSetDefaultVote, extractAlertInfo, extractPostAuthorKey, extractTopicAuthorKey };
