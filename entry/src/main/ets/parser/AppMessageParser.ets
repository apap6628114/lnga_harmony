/**
 * 官方 APP 私信接口解析（消息页会话列表 message/list、会话内消息 message/detail）。
 *
 * 官方接口（app_api.php + POST form + sign，__output=12）与 nuke.php 网页版
 * （__lib=message&__act=message&act=list|read&lite=js）响应形状完全不同：
 *
 * message/list（实测 ngabbs.com，__output=12）：
 *   {"code":0,"msg":"操作成功","result":[{"did":3405931,"bit":8,"subject":"...",
 *    "from_uid":0,"from_username":"","addTime":1631062273,"posts_num":389,
 *    "last_modify":1777225492,"last_from":0,"last_from_username":""}],
 *    "currentPage":1,"nextPage":false,"perPage":35}
 *   - result 为会话数组（非网页版 data.data 数字键字典），元素 did 为会话 ID
 *   - 分页信息在响应顶层：currentPage / nextPage（bool，true=还有下一页）/
 *     perPage（每页条数）
 *
 * message/detail（实测 ngabbs.com，__output=12，signParams=did）：
 *   {"code":0,"msg":"操作成功","result":[{"id":253649708,"subject":"...",
 *    "content":"...<br/>[quote]...[/quote]...","addTime":1777225492,
 *    "user":{"uid":0,"username":"#SYSTEM#"}}]}
 *   - result 为消息数组，元素 user 内嵌发送人（uid=0 为系统消息）
 *   - content 为 HTML+BBCode 混合文本（含 <br/> 换行标签），统一转为 \n
 *   - 官方响应无网页版的 title/alluser 分页字段；标题以首条消息 subject 兜底
 *
 * 错误形状：code!=0 时 msg 携带错误文案（如 {"code":4,"msg":"参数错误"}）。
 *
 * 纯函数模块，不依赖 AppStore / 网络，可直接被 Hypium Local Test 覆盖。
 */

import type {
  MessageListInfo,
  MessageThreadInfo,
  MessageDetailInfo,
  MessageArticle,
} from '../model/Message'

/**
 * 提取官方接口的业务错误文案。
 *
 * @param raw - 官方接口响应
 * @returns 错误文案；code=0（成功）或形状缺失时返回 null
 */
export function extractAppMessageError(raw: object): string | null {
  const rec: Record<string, Object> = raw as Record<string, Object>
  const code: number = Number(rec['code'] ?? 0)
  if (code === 0) {
    return null
  }
  const msg: Object | undefined = rec['msg']
  return msg !== undefined && msg !== null ? String(msg) : `错误码: ${code}`
}

/**
 * 归一化官方私信正文：<br> 系列换行标签转 \n，其余 HTML 标签剥离。
 *
 * 官方 content 为 HTML+BBCode 混合文本（实测含 <br/>、[quote] 等）。仅转 <br>
 * 会把 <img>/<a> 等其余标签字面展示给用户，故按项目既有清洗范式
 * （ShareUtils.sharePost）一并剥离 <[^>]+>，得到与网页版一致的纯 BBCode 文本，
 * 后续由 UI 经 unescapeHtml 处理实体。
 *
 * @param content - 原始正文
 * @returns 归一化正文
 */
export function normalizeAppMessageContent(content: string): string {
  return content.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '')
}

/**
 * 从官方 message/list 响应解析会话列表（映射为网页版 MessageListInfo 同形状）。
 *
 * 字段映射：did→mid、addTime→time、last_modify→lasttime、posts_num→posts，
 * from_username / last_from_username 同名透传。from_uid=0 表示系统消息
 * （网页版同样以 from_username 为空表达，UI 无需区分）。
 *
 * @param raw - 官方接口响应
 * @param page - 请求页码（currentPage 缺失时的兜底）
 * @returns 会话列表信息；业务失败（code!=0）或 result 形状不可识别时返回 null
 */
export function parseAppMessageList(raw: object, page: number): MessageListInfo | null {
  const rec: Record<string, Object> = raw as Record<string, Object>
  const code: number = Number(rec['code'] ?? 0)
  if (code !== 0) {
    return null
  }
  const res: Object | undefined = rec['result']
  if (res === undefined || res === null || !Array.isArray(res)) {
    return null
  }
  const arr: Object[] = res as Object[]
  const messages: MessageThreadInfo[] = []
  for (let i = 0; i < arr.length; i++) {
    const v: Object | undefined = arr[i]
    if (v === undefined || v === null || typeof v !== 'object' || Array.isArray(v)) {
      continue
    }
    const item: Record<string, Object> = v as Record<string, Object>
    const did: number = Number(item['did'] ?? 0)
    if (did <= 0) {
      continue
    }
    const msg: MessageThreadInfo = {
      mid: did,
      subject: String(item['subject'] ?? ''),
      time: String(item['addTime'] ?? ''),
      lasttime: String(item['last_modify'] ?? ''),
      posts: Number(item['posts_num'] ?? 0),
      from_username: String(item['from_username'] ?? ''),
      last_from_username: String(item['last_from_username'] ?? ''),
    }
    messages.push(msg)
  }

  const currentPageRaw: number = Number(rec['currentPage'] ?? 0)
  const perPageRaw: number = Number(rec['perPage'] ?? 0)
  const hasNext: boolean = rec['nextPage'] === true || rec['nextPage'] === 'true'
  const currentPage: number = currentPageRaw > 0 ? currentPageRaw : page

  const info: MessageListInfo = {
    rowsPerPage: perPageRaw > 0 ? perPageRaw : 20,
    nextPage: hasNext ? currentPage + 1 : 0,
    currentPage: currentPage > 0 ? currentPage : 1,
    messageEntryList: messages,
  }
  return info
}

/**
 * 从官方 message/detail 响应解析会话内消息（映射为网页版 MessageDetailInfo 同形状）。
 *
 * 字段映射：id 不展示（会话 ID 由调用方持有）、subject/addTime/content 同名映射，
 * author/from 均取 user.username（网页版 author=发送人名、from=发送人名，语义一致）；
 * 官方版无 js_escap_avatar/yz/mute_time/signature/formated_html_data，置空
 * （UI 对 formated_html_data 为空走纯文本分支）。
 *
 * 标题兜底：官方响应无 title 字段，以首条消息 subject 作为会话标题
 * （与网页版 data.title 语义近似）。
 *
 * @param raw - 官方接口响应
 * @param page - 请求页码（currentPage 兜底）
 * @returns 会话内消息信息；业务失败（code!=0）或 result 形状不可识别时返回 null
 */
export function parseAppMessageDetail(raw: object, page: number): MessageDetailInfo | null {
  const rec: Record<string, Object> = raw as Record<string, Object>
  const code: number = Number(rec['code'] ?? 0)
  if (code !== 0) {
    return null
  }
  const res: Object | undefined = rec['result']
  if (res === undefined || res === null || !Array.isArray(res)) {
    return null
  }
  const arr: Object[] = res as Object[]
  const articles: MessageArticle[] = []
  for (let i = 0; i < arr.length; i++) {
    const v: Object | undefined = arr[i]
    if (v === undefined || v === null || typeof v !== 'object' || Array.isArray(v)) {
      continue
    }
    const item: Record<string, Object> = v as Record<string, Object>
    const id: number = Number(item['id'] ?? 0)
    if (id <= 0) {
      continue
    }
    const user: Object | undefined = item['user']
    let username: string = ''
    if (user !== undefined && user !== null && typeof user === 'object' && !Array.isArray(user)) {
      username = String((user as Record<string, Object>)['username'] ?? '')
    }
    const article: MessageArticle = {
      subject: String(item['subject'] ?? ''),
      time: String(item['addTime'] ?? ''),
      content: normalizeAppMessageContent(String(item['content'] ?? '')),
      from: username,
      lou: 0,
      js_escap_avatar: '',
      author: username,
      yz: '',
      mute_time: '',
      signature: '',
      formated_html_data: '',
    }
    articles.push(article)
  }

  const allUsers: Object | undefined = rec['allUsers']
  const title: string = articles.length > 0 ? articles[0].subject : ''
  const info: MessageDetailInfo = {
    nextPage: 0,
    currentPage: page > 0 ? page : 1,
    // allUsers 官方为 JSON 串（回复页使用）；非字符串（对象/数字）时置空避免
    // String() 产生 "[object Object]"，UI 当前不消费该字段
    alluser: typeof allUsers === 'string' ? allUsers : '',
    title: title,
    messageEntryList: articles,
  }
  return info
}
