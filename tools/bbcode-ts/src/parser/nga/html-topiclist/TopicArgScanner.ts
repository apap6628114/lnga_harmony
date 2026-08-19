/**
 * NGA topicArg 调用参数扫描 — 提取 commonui.topicArg.add(...) 调用的参数体。
 *
 * thread.php 主题列表页（含 authorid= 用户发帖/回帖记录页）的每一行主题，
 * 服务端会在行 DOM 后输出一段 `commonui.topicArg.add(...)` 脚本，携带该主题
 * 的元数据（fid/tid/pid/postdate/lastpost/replies/type/topicMisc 等）。
 *
 * 参数位置约定（共 21 个形参，实参可多传被 JS 忽略）：
 *   [0..6]  idReplies,idTopic,idAuthor,idPostTime,idReplier,idReplyTime,idPagelinks
 *   [7]     fid
 *   [8]     tid
 *   [9]     pid（回帖模式 searchpost=1 时有效，发帖模式为空）
 *   [10]    quoteTid（镜像主题 tid）
 *   [11]    quoteFrom（引用来源，镜像分页用 quote_from||tid）
 *   [12]    postdate（主题发帖时间戳）
 *   [13]    lastpost（最后回复时间戳）
 *   [14]    replies（回帖数）
 *   [15]    type（类型位：&65536 集合帖 / &32768 合集帖 / &2097152 版面帖）
 *   [16]    topicMisc（base64 元数据）
 *   [17]    font
 *   [18..20] avatar,admin,attath
 *
 * 与 JSON API（thread.php?lite=js 或 __output=3）的 __T 条目字段同源：
 * fid/tid/type/postdate/lastpost/replies/quote_from/topic_misc 逐一对应。
 *
 * `()` 参数体提取统一走 scanBalanced（见 html-thread/ScanState），
 * 顶层逗号切分复用 html-thread/PostArgScanner 的 splitTopLevelArgs。
 */

import { scanBalanced } from '../html-thread/ScanState';
import { splitTopLevelArgs } from '../html-thread/PostArgScanner';

const TOPIC_ADD_MARKER: string = 'commonui.topicArg.add(';

/**
 * 单条 topicArg.add 调用解析后的结构化数据。
 */
interface TopicArgData {
  fid: number;
  tid: number;
  pid: number;
  quoteTid: number;
  quoteFrom: number;
  postdate: number;
  lastpost: number;
  replies: number;
  type: number;
  topicMisc: string;
  font: string;
}

/**
 * 解析 JS 字面量参数片段为数字（去引号、容忍 null/undefined）。
 *
 * @param raw 原始参数片段（如 `'781'`、`44627932`、`null`、`''`）
 * @returns 数字值；无法解析时返回 0
 */
function toInt(raw: string): number {
  const cleaned: string = raw.replace(/'/g, '').trim();
  const n: number = parseInt(cleaned, 10);
  if (isNaN(n)) {
    return 0;
  }
  return n;
}

/**
 * 解析 JS 字面量参数片段为字符串（去引号、null/undefined 归一为空串）。
 *
 * @param raw 原始参数片段
 * @returns 字符串值
 */
function toStr(raw: string): string {
  const cleaned: string = raw.replace(/'/g, '').trim();
  if (cleaned === 'null' || cleaned === 'undefined') {
    return '';
  }
  return cleaned;
}

/**
 * 扫描 HTML 中所有 commonui.topicArg.add(...) 调用，解析为序号 → 数据映射。
 *
 * 序号（0,1,2,...）与页面行 DOM 的 id 后缀（t_tt1_0 / t_tt1_1 / ...）一一对应，
 * 也与 JSON API __T 的索引键一致，可作为 __T 的键。
 *
 * @param html NGA thread.php 主题列表页 HTML
 * @returns 序号到 TopicArgData 的映射
 */
function parseAllTopicArgs(html: string): Map<number, TopicArgData> {
  const result: Map<number, TopicArgData> = new Map();
  let searchFrom: number = 0;
  let seq: number = 0;
  while (true) {
    const startIdx: number = html.indexOf(TOPIC_ADD_MARKER, searchFrom);
    if (startIdx < 0) {
      break;
    }
    const openPos: number = startIdx + TOPIC_ADD_MARKER.length - 1;
    const matched = scanBalanced(html, openPos, '(', ')');
    if (!matched.value) {
      break;
    }
    const callArgsStr: string = matched.value.substring(1, matched.value.length - 1);
    const args: string[] = splitTopLevelArgs(callArgsStr);
    if (args.length >= 18) {
      const data: TopicArgData = {
        fid: toInt(args[7]),
        tid: toInt(args[8]),
        pid: toInt(args[9]),
        quoteTid: toInt(args[10]),
        quoteFrom: toInt(args[11]),
        postdate: toInt(args[12]),
        lastpost: toInt(args[13]),
        replies: toInt(args[14]),
        type: toInt(args[15]),
        topicMisc: toStr(args[16]),
        font: toStr(args[17]),
      };
      result.set(seq, data);
      seq++;
    }
    searchFrom = startIdx + TOPIC_ADD_MARKER.length;
  }
  return result;
}

export { TopicArgData, parseAllTopicArgs };
