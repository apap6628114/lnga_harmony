/**
 * 官方 APP thread.php 主题列表解析（板块内帖子列表 / 主题搜索官方签名通道）。
 *
 * 官方客户端（nga.apk v7.17.17）的版面主题列表走 thread.php 入口（无 __lib/__act，
 * POST form + 公共参数签名，__output=14，signParams = fid 或 key），与鸿蒙端
 * 之前的网页版 JSON 通道（GET thread.php?lite=js&noprefix）响应形状不同。
 * 本模块负责官方响应的：
 *  - 业务错误提取（code!=0 → msg，如 2048 页面错误 / 15 频率限制）
 *  - 形状归一化（外层 {code,result} → parseTopicList 兼容的 {data,time}）
 *  - 缺失服务端时间戳时以本地时间兜底（官方响应无 time 字段）
 *
 * 实测响应形状（nga-hack nga-client 探测，fid=7）：
 *   {"code":0,"result":{"__CU":{...},"__GLOBAL":{...},"__ROWS":3741919,
 *    "__T":[{tid,fid,author,authorid,subject,type,postdate,lastpost,lastposter,
 *      replies,lastmodify,recommend,jdata,attachs,tpcurl,topic_misc_var,parent,...}],
 *    "__T__ROWS":54,"__T__ROWS_PAGE":35,"__R__ROWS_PAGE":20,
 *    "__F":{"fid":7,"name":"...","topped_topic":...,"sub_forums":{...},
 *      "__SELECTED_FORUM":null}}}
 *  - result.__T 为**数组**（网页版为 tid 键字典）；parseTopicList 的数字键遍历兼容数组
 *  - result.__F.sub_forums 为「数字键/t合集键 → 数组值」字典，数组值
 *    [fid, 名称, 简介, tid, 类型位]（parseSubBoards 已按 fid 语义解析）
 *  - 顶层无 time（网页版有）→ 归一化时以本地秒级时间戳兜底（24 小时热门窗口依赖 curTime）
 *
 * 纯函数模块，不依赖 AppStore / 网络，可直接被 Hypium Local Test 覆盖。
 */

import { parseTopicList } from './TopicParser'
import { parseNgaError } from './ErrorParser'
import type { TopicListInfo } from '../model/Topic'

/**
 * 从官方 thread.php 响应中提取业务错误信息。
 *
 * 官方响应 `{code, result}` 与网页版不同：无 `error` 对象，业务失败时
 * `code != 0` 且 `msg` 为人类可读错误（如 2048「页面错误」、15「频率限制」、
 * 5「签名错误」）。
 *
 * 同时兼容 ngaRequest 对 HTTP 层 HTML 错误页的归一化形状
 * （`{error:{0:...}, error_code}`，见 NgaClient.ngaRequest），透传真实错误
 * 而非退化为「解析失败」。
 *
 * @param raw - 官方接口响应
 * @returns 错误信息；code=0 或形状不可识别时返回 null
 */
export function extractAppTopicListError(raw: object): string | null {
  const rec: Record<string, Object> = raw as Record<string, Object>;
  const webError: string | null = parseNgaError(raw);
  if (webError !== null) {
    return webError;
  }
  const code: number = Number(rec['code'] ?? 0);
  if (code === 0) {
    return null;
  }
  const msg: string = String(rec['msg'] ?? '');
  if (msg.length > 0) {
    return msg;
  }
  return `错误码: ${code}`;
}

/**
 * 把官方 thread.php 响应解析为与网页版同形状的 TopicListInfo。
 *
 * 归一化：`{code:0, result:{__T,...}}` → `{data: result', time: <本地时间>}`，
 * 其中 result' 的 `__T` 显式归一化为数字键 Record（官方为数组，网页版为 tid
 * 字典；parseTopicList 统一按数字键遍历），随后复用 parseTopicList。
 *
 * @param raw - 官方接口响应
 * @param blacklist - 用户黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param currentPage - 当前页码（官方响应无 __PAGE，由调用方传入）
 * @param curTime - 服务端当前时间（秒）；<=0 时以本地时间兜底
 * @returns 主题列表信息；业务失败（code!=0）或形状不可识别（result 非对象/缺 __T）时返回 null
 */
export function parseAppTopicList(raw: object, blacklist: Set<string>, keywords: string[],
  currentPage: number, curTime: number = 0): TopicListInfo | null {
  const rec: Record<string, Object> = raw as Record<string, Object>;
  const code: number = Number(rec['code'] ?? 0);
  if (code !== 0) {
    return null;
  }
  const res: Object | undefined = rec['result'];
  if (res === undefined || res === null || typeof res !== 'object' || Array.isArray(res)) {
    return null;
  }
  const resRec: Record<string, Object> = res as Record<string, Object>;
  const tVal: Object | undefined = resRec['__T'];
  if (tVal === undefined || tVal === null) {
    return null;
  }
  // 拷贝 result（不变异调用方对象），并把 __T 显式归一化为数字键 Record
  const resCopy: Record<string, Object> = {};
  const resKeys: string[] = Object.keys(resRec);
  for (let i = 0; i < resKeys.length; i++) {
    resCopy[resKeys[i]] = resRec[resKeys[i]];
  }
  if (Array.isArray(tVal)) {
    const t: Record<string, Object> = {};
    const arr: Object[] = tVal as Object[];
    for (let i = 0; i < arr.length; i++) {
      const item: Object | undefined = arr[i];
      if (item !== undefined && item !== null && typeof item === 'object' && !Array.isArray(item)) {
        t[String(i)] = item;
      }
    }
    resCopy['__T'] = t;
  } else if (typeof tVal !== 'object') {
    return null;
  }
  const fakeRaw: Record<string, Object> = {};
  fakeRaw['data'] = resCopy;
  fakeRaw['time'] = curTime > 0 ? curTime : Math.floor(Date.now() / 1000);
  return parseTopicList(fakeRaw, blacklist, keywords, currentPage);
}
