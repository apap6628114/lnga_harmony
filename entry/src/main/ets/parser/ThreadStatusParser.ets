/**
 * 官方 APP 帖子状态响应解析（跟踪帖子更新专用）。
 *
 * 取数通道：`read.php` App 签名 POST + `__output=8`（与帖子详情 HTML 通道同源同鉴权，
 * 但响应仅约 20KB，且直接带 `__T` 主题字段，无需 HTML 解析）。实测形状：
 *
 * 正常：
 * ```text
 * {"data":{"__CU":…,"__U":…,"__R":{…},"__T":{"fid":-7,"tid":44191387,
 *   "subject":"…","locked":0,"replies":554,"authorid":205511,
 *   "lastpost":1790330724,"lastposter":"…"},
 *   "__ROWS":555,"__R__ROWS_PAGE":20,"__PAGE":1},"encode":"GBK","time":…}
 * ```
 * 失效（主题不存在 / 被删除）：
 * ```text
 * {"error":{"0":"2048:找不到主题","1":"","2":""},
 *  "data":{"__MESSAGE":{"0":2048,"1":"找不到主题","3":200}},"encode":"gbk","time":…}
 * ```
 *
 * `__ROWS` 是主题总行数（含主楼），`__T.replies` 是总回复数，两者恒差 1；
 * `replies` 缺失时以 `__ROWS - 1` 兜底。
 *
 * 纯函数模块，不依赖 AppStore / 网络，可直接被 Hypium Local Test 覆盖。
 */

import { parseNgaError } from './ErrorParser'
import { ThreadTrackStatus } from '../model/TrackedThread'

/**
 * 从响应中提取服务端**业务**错误原因（只认 `data.__MESSAGE[1]`）。
 *
 * ⚠️ 这里是「帖子失效」的**唯一**判据，必须严格：NGA 的失效响应形如
 * `{"error":{…},"data":{"__MESSAGE":{"0":2048,"1":"找不到主题","3":200}}}`，
 * 业务错误体一定带 `data.__MESSAGE`。
 *
 * 反过来，`NgaClient.ngaRequest` 会把**任何**以 `<!DOCTYPE`/`<html` 开头的响应
 * （频率限制页 / 维护页 / WAF 页 / 登录跳转页）归一化成 `{error:{0:…}}`，
 * 那也是非空的 `error` 文本。若拿它当失效依据，一次服务端抖动就会把用户
 * 全部跟踪任务当成"帖子已失效"删掉——因此本函数**刻意不看**顶层 `error`。
 * 顶层 `error` 只作失败诊断文案（见 {@link parseThreadTrackStatus}）。
 *
 * @param raw - 响应对象
 * @returns 业务错误原因；无业务错误体时返回空串
 */
function extractDataMessage(raw: Record<string, Object>): string {
  const data: Object | undefined = raw['data']
  if (data === undefined || data === null || typeof data !== 'object' || Array.isArray(data)) {
    return ''
  }
  const message: Object | undefined = (data as Record<string, Object>)['__MESSAGE']
  if (message === undefined || message === null || typeof message !== 'object'
    || Array.isArray(message)) {
    return ''
  }
  return String((message as Record<string, Object>)['1'] ?? '').trim()
}

/**
 * 提取失败诊断文案（顶层 `error`），仅用于日志与 UI 提示，不参与失效判定。
 *
 * @param raw - 响应对象
 * @returns 诊断文案；无错误信息时返回空串
 */
function extractFailureReason(raw: Record<string, Object>): string {
  const fallback: string | null = parseNgaError(raw)
  return fallback === null ? '' : fallback
}

/**
 * 从 `__T` 中取主题条目（兼容直接对象与以 tid 为键的字典两种形状）。
 *
 * @param data - 响应的 data 对象
 * @returns 主题条目；形状不可识别时返回 null
 */
function extractTopicInfo(data: Record<string, Object>): Record<string, Object> | null {
  const rawT: Object | undefined = data['__T']
  if (rawT === undefined || rawT === null || typeof rawT !== 'object' || Array.isArray(rawT)) {
    return null
  }
  const t: Record<string, Object> = rawT as Record<string, Object>
  if (t['tid'] !== undefined && t['tid'] !== null) {
    return t
  }
  const keys: string[] = Object.keys(t)
  for (let index: number = 0; index < keys.length; index++) {
    const candidate: Object | undefined = t[keys[index]]
    if (candidate !== undefined && candidate !== null && typeof candidate === 'object'
      && !Array.isArray(candidate)) {
      const record: Record<string, Object> = candidate as Record<string, Object>
      if (record['tid'] !== undefined && record['tid'] !== null) {
        return record
      }
    }
  }
  return null
}

/**
 * 解析帖子状态响应。
 *
 * @param raw - `read.php __output=8` 响应对象（已由 NgaClient 按 GB18030 解码并净化）
 * @returns 状态结果：成功 / 失效 / 请求失败三态
 */
export function parseThreadTrackStatus(raw: object): ThreadTrackStatus {
  const status: ThreadTrackStatus = new ThreadTrackStatus()
  const rec: Record<string, Object> = raw as Record<string, Object>
  if (rec['__parseError'] === true) {
    status.reason = '响应解析失败'
    return status
  }

  const dataValue: Object | undefined = rec['data']
  if (dataValue === undefined || dataValue === null || typeof dataValue !== 'object'
    || Array.isArray(dataValue)) {
    // 无 data：可能是请求/解析失败，也可能是 NgaClient 归一化后的 HTML 错误页
    // （频率限制 / 维护页 / WAF 页）。**一律不判失效**，只作可重试失败，
    // 否则一次服务端抖动就会把全部跟踪任务清空。
    const reason: string = extractFailureReason(rec)
    status.reason = reason.length > 0 ? reason : '响应缺少数据'
    return status
  }
  const data: Record<string, Object> = dataValue as Record<string, Object>

  const topic: Record<string, Object> | null = extractTopicInfo(data)
  const totalRows: number = Number(data['__ROWS'] ?? 0)
  if (topic === null) {
    // 失效只由服务端业务错误体（data.__MESSAGE）决定
    const businessMessage: string = extractDataMessage(rec)
    if (businessMessage.length > 0) {
      status.invalid = true
      status.reason = businessMessage
      return status
    }
    if (totalRows > 0) {
      // 有行数但缺主题表：以行数兜底（保留跟踪，等下轮检查）
      status.ok = true
      status.totalReplies = totalRows - 1
      return status
    }
    // 无业务错误体：可重试失败。顶层 error（若有）只作诊断文案，不作失效依据
    const diagnostic: string = extractFailureReason(rec)
    status.reason = diagnostic.length > 0 ? diagnostic : '帖子数据异常'
    return status
  }

  const topicTid: number = Number(topic['tid'] ?? 0)
  if (topicTid <= 0) {
    status.reason = '帖子标识异常'
    return status
  }
  const rawReplies: Object | undefined = topic['replies']
  const repliesText: string = rawReplies === undefined || rawReplies === null
    ? ''
    : String(rawReplies).trim()
  const parsedReplies: number = repliesText.length > 0 ? Number(repliesText) : NaN
  const fallbackReplies: number = totalRows > 0 ? totalRows - 1 : 0
  // 非数字/空串/负数一律退回 __ROWS-1：把「解析不出来的回复数」当成 0 会让基准被拉平，
  // 下一轮拿到正常值时就变成凭空的「+N 条新回复」
  const replies: number = Number.isFinite(parsedReplies) && parsedReplies >= 0
    ? parsedReplies
    : fallbackReplies
  status.ok = true
  status.totalReplies = replies > 0 ? replies : 0
  status.lastPostTs = Number(topic['lastpost'] ?? 0)
  status.subject = String(topic['subject'] ?? '')
  status.author = String(topic['author'] ?? '')
  status.authorid = Number(topic['authorid'] ?? 0)
  status.fid = Number(topic['fid'] ?? 0)
  status.locked = Number(topic['locked'] ?? 0) !== 0
  return status
}
