/**
 * 官方 APP 版面主题列表/搜索解析（app_api.php subject/list | subject/search）。
 *
 * 官方客户端（nga.apk v7.17.17）的版面主题列表走 SUBJECT_LIST = app_api.php
 * subject/list（ct.d.d pswitch_522 映射；搜索走 SUBJECT_SEARCH = subject/search，
 * pswitch_50e），与鸿蒙端之前的 thread.php 官方签名通道（POST form + sign，
 * result.__T/__F 形状）不同。本模块负责官方 subject 系响应的：
 *  - 业务错误提取（code!=0 → msg，如 5 签名错误 / 15 频率限制）
 *  - 主题条目归一化（result.data 数组元素 → parseTopicList 兼容形状；
 *    forumname→parent、titlefont_api→titlefont 位值、attachs 透传）
 *  - 子版块列表解析（result.subForum → SubBoard，checked/allow_checked 为
 *    账号级真实订阅状态，替代 thread.php 网页版 sub_forums 的 attributes 启发式）
 *  - 分页信息解析（totalPage 在响应顶层或 result 内，值可能为 string）
 *  - 缺失服务端时间戳时以本地时间兜底（官方 subject 系响应无 time 字段）
 *
 * 实测响应形状（nga-hack nga-client 探测，fid=7，登录态）：
 *   {"code":0,"msg":"操作成功",
 *    "result":{"attachPrefix":"https://img.nga.cn/attachments/",
 *      "subForum":[{"0":255,"1":"团队管理经验交流","2":"管理经验交流","3":14673796,
 *        "4":2606,"id":255,"name":"...","info":"...","checked":1,"allow_checked":1,
 *        "sub_type":2606,"tid":14673796}, ...],
 *      "topic_key":"...","sessionPrivilege":"...","data":[{tid,fid,author,authorid,
 *        subject,postdate,lastpost,lastposter,replies,type,attachs,titlefont_api,
 *        style,topic_misc_var_bit1,set_elm_parent,is_set_elm,forumname}, ...],
 *      "unionforum_ary_all":[],"header":{...}},
 *    "totalPage":106923,"total":3742292,"currentPage":1,"perPage":35,
 *    "forumname":"...","fid":7,"bit_data":...,"__CURRENT_ORDER":""}
 *  - subForum 元素为「位置字段 + 命名键」双格式；checked=当前账号订阅状态、
 *    allow_checked=是否允许订阅（allow_checked=0 的版面服务端已排除其主题混合）
 *  - data 元素无 parent/titlefont/topic_misc（thread.php 有）；titlefont_api
 *    为 {color,bold,italic,underline} 对象，需转位值（1 红 2 金 4 绿 8 橙 16 灰，
 *    32 粗 64 斜 128 删）
 *  - 搜索（subject/search）响应同构：result.data + 顶层 totalPage，无 subForum
 *
 * 纯函数模块，不依赖 AppStore / 网络，可直接被 Hypium Local Test 覆盖。
 */

import { parseTopicList } from './TopicParser'
import { normalizeAppUserTopicItem } from './AppUserTopicParser'
import { parseNgaError } from './ErrorParser'
import type { TopicListInfo } from '../model/Topic'
import type { SubBoard } from '../model/Forum'
import { NGA_IMG4_BASE } from '../common/constants/NgaDomains'

/**
 * 从官方 subject 系响应中提取业务错误信息。
 *
 * 官方响应 `{code, result}` 与网页版不同：无 `error` 对象，业务失败时
 * `code != 0` 且 `msg` 为人类可读错误（如 5「签名错误」、15「频率限制」）。
 * 同时兼容 ngaRequest 对 HTTP 层 HTML 错误页的归一化形状
 * （`{error:{0:...}, error_code}`，见 NgaClient.ngaRequest）。
 *
 * @param raw - 官方接口响应
 * @returns 错误信息；code=0 或形状不可识别时返回 null
 */
export function extractSubjectListError(raw: object): string | null {
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
 * 从官方 subject 系响应中提取主题条目数组（归一化后，parseTopicList 兼容）。
 *
 * 归一化规则（normalizeAppUserTopicItem 基础上补齐 subject 系差异）：
 *  - forumname → parent['2']（版面名）
 *  - titlefont_api（{color,bold,italic,underline}）→ titlefont 位值字符串
 *  - attachs/error 等原始字段透传
 *
 * @param raw - 官方接口响应
 * @returns 归一化后的条目数组；接口业务失败（code!=0）或形状不可识别时返回 null
 */
export function extractSubjectTopicItems(raw: object): Record<string, Object>[] | null {
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
  const data: Object | undefined = resRec['data'];
  if (!Array.isArray(data)) {
    return null;
  }
  const items: Record<string, Object>[] = [];
  const arr: Object[] = data as Object[];
  for (let i = 0; i < arr.length; i++) {
    const item: Object | undefined = arr[i];
    if (item === undefined || item === null || typeof item !== 'object' || Array.isArray(item)) {
      continue;
    }
    items.push(normalizeSubjectTopicItem(item as Record<string, Object>));
  }
  return items;
}

/**
 * 把官方 subject 系单个主题条目归一化为 parseTopicList 兼容形状。
 *
 * @param item - 官方接口条目
 * @returns 归一化条目
 */
function normalizeSubjectTopicItem(item: Record<string, Object>): Record<string, Object> {
  const out: Record<string, Object> = normalizeAppUserTopicItem(item);
  const fontApi: Object | undefined = item['titlefont_api'];
  if (fontApi !== undefined && fontApi !== null && typeof fontApi === 'object'
    && !Array.isArray(fontApi)) {
    const bit: string = convertTitleFontApi(fontApi as Record<string, Object>);
    if (bit.length > 0) {
      out['titlefont'] = bit;
    }
  }
  return out;
}

/**
 * 把 titlefont_api 对象转换为 titlefont 位值字符串。
 *
 * 位映射与页面层 titlefont 位解析一致（FONT_COLORS：1 红 2 金 4 绿 8 橙 16 灰；
 * 32 粗 64 斜 128 删）。
 *
 * @param fontApi - titlefont_api 对象
 * @returns 位值字符串；无任何字体标记时返回空串
 */
export function convertTitleFontApi(fontApi: Record<string, Object>): string {
  let bit: number = 0;
  const color: string = String(fontApi['color'] ?? '');
  if (color === 'red') {
    bit |= 1;
  } else if (color === 'gold') {
    bit |= 2;
  } else if (color === 'green') {
    bit |= 4;
  } else if (color === 'orange') {
    bit |= 8;
  } else if (color === 'gray' || color === 'silver') {
    bit |= 16;
  }
  if (fontApi['bold'] === true) {
    bit |= 32;
  }
  if (fontApi['italic'] === true) {
    bit |= 64;
  }
  if (fontApi['underline'] === true) {
    bit |= 128;
  }
  return bit === 0 ? '' : String(bit);
}

/**
 * 从官方 subject/list 响应中解析子版块列表（result.subForum → SubBoard）。
 *
 * checked = 当前账号对该子版块的订阅状态（1 订阅 → 主题混合显示；0 未订阅 →
 * 服务端已排除其主题）；allow_checked = 是否允许用户订阅（0 的版面在 UI 上
 * 禁用开关）。filterId 取 subForum.tid（635 版镜像 id，与 thread.php 网页版
 * sub_forums 数组下标 3 同语义，供 subject/subscription 提交）。
 *
 * @param res - 官方响应 result 对象
 * @returns 子版块列表
 */
export function parseSubjectSubBoards(res: Record<string, Object> | undefined): SubBoard[] {
  const result: SubBoard[] = [];
  if (res === undefined || res === null) {
    return result;
  }
  const raw: Object | undefined = res['subForum'];
  if (!Array.isArray(raw)) {
    return result;
  }
  const arr: Object[] = raw as Object[];
  for (let i = 0; i < arr.length; i++) {
    const item: Object | undefined = arr[i];
    if (item === undefined || item === null || typeof item !== 'object' || Array.isArray(item)) {
      continue;
    }
    const sub: SubBoard | null = parseSubjectSubBoard(item as Record<string, Object>);
    if (sub !== null) {
      result.push(sub);
    }
  }
  return result;
}

/**
 * 把 subForum 单个元素解析为 SubBoard。
 *
 * @param item - subForum 元素（位置字段 + 命名键双格式）
 * @returns 子版块；字段缺失或非法时返回 null
 */
function parseSubjectSubBoard(item: Record<string, Object>): SubBoard | null {
  const idValue: Object | undefined = item['id'] ?? item['0'];
  const nameValue: Object | undefined = item['name'] ?? item['1'];
  const infoValue: Object | undefined = item['info'] ?? item['2'];
  const tidValue: Object | undefined = item['tid'] ?? item['3'];
  const subTypeValue: Object | undefined = item['sub_type'] ?? item['4'];
  if (idValue === undefined || nameValue === undefined || tidValue === undefined
    || subTypeValue === undefined) {
    return null;
  }
  const id: number = Number(idValue);
  const name: string = String(nameValue);
  const tid: string = String(tidValue);
  const subType: number = Number(subTypeValue);
  if (!Number.isFinite(id) || name.length === 0 || tid.length === 0 || !Number.isFinite(subType)) {
    return null;
  }
  const checked: boolean = Number(item['checked'] ?? 0) === 1;
  const allowChecked: boolean = Number(item['allow_checked'] ?? 1) === 1;
  return {
    fid: id,
    stid: 0,
    name: name,
    boardHead: `${NGA_IMG4_BASE}/ngabbs/nga_classic/f/app/${id}.png`,
    tidStr: tid,
    type: subType,
    checked: checked,
    description: infoValue === undefined || infoValue === null ? '' : String(infoValue),
    parentFidStr: '',
    filterId: tid,
    attributes: subType,
    filterable: allowChecked,
  };
}

/**
 * 把官方 subject/list|search 响应解析为与 parseTopicList 同形状的 TopicListInfo。
 *
 * 分页信息解析（实测 totalPage 在响应顶层，值可能为 string；result 内回退兼容）：
 *  - totalPage>0 → 作为总页数（权威值）
 *  - 缺失 totalPage 时：本页条目为空 → totalPages=page（已到底）；非空 →
 *    totalPages=page+1（乐观，继续翻页直到真空页）
 *  - 业务失败（code!=0）→ 返回 null
 *
 * @param raw - 官方接口响应
 * @param blacklist - 用户黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param page - 当前页码
 * @returns 主题列表信息；业务失败或形状不可识别时返回 null
 */
export function parseSubjectList(raw: object, blacklist: Set<string>, keywords: string[],
  page: number): TopicListInfo | null {
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
  const rawArr: Record<string, Object>[] | null = extractSubjectTopicItems(raw);
  if (rawArr === null) {
    return null;
  }
  let totalPage: number = Number(rec['totalPage'] ?? 0) || 0;
  if (totalPage <= 0) {
    totalPage = Number(resRec['totalPage'] ?? 0) || 0;
  }
  const t: Record<string, Object> = {};
  for (let i = 0; i < rawArr.length; i++) {
    t[String(i)] = rawArr[i];
  }
  const dataObj: Record<string, Object> = {};
  dataObj['__T'] = t;
  // 版块名透传（subject/list 响应顶层 forumname；parseTopicList 从 __F.name 读取）
  const forumname: string = String(rec['forumname'] ?? '');
  if (forumname.length > 0) {
    const forum: Record<string, Object> = {};
    forum['name'] = forumname;
    dataObj['__F'] = forum;
  }
  if (totalPage > 0) {
    // rowsPerPage=1：calcPagination 得 totalPages = ceil(totalPage/1) = totalPage
    dataObj['__ROWS'] = totalPage;
    dataObj['__T__ROWS_PAGE'] = 1;
  } else {
    const fallbackPages: number = rawArr.length === 0 ? page : page + 1;
    dataObj['__ROWS'] = fallbackPages;
    dataObj['__T__ROWS_PAGE'] = 1;
  }
  const fakeRaw: Record<string, Object> = {};
  fakeRaw['data'] = dataObj;
  fakeRaw['time'] = Math.floor(Date.now() / 1000);
  const base: TopicListInfo = parseTopicList(fakeRaw, blacklist, keywords, page);
  // 子版块列表（subForum.checked 账号级真实订阅状态）由本解析器填充：
  // parseTopicList 的通用输入（thread.php __T 形状）不含 subForum，恒返回空列表。
  const subs: SubBoard[] = parseSubjectSubBoards(resRec);
  const info: TopicListInfo = {
    name: base.name,
    threadPageList: base.threadPageList,
    subBoardList: subs,
    curTime: base.curTime,
    pagination: base.pagination,
  };
  return info;
}
