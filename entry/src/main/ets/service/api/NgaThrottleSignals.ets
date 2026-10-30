/**
 * NGA 风控信号与重试安全的纯函数判定。
 *
 * 这一层刻意保持**无状态、无依赖**：NgaClient 用它决定「要不要重试 / 要不要进冷却」，
 * Hypium 单测直接对函数取值。所有判断都必须是确定性的纯逻辑，不允许在这里发请求
 * 或读全局状态，否则单测与线上会走出两条不同的路径。
 *
 * 为什么需要它（改造前的问题）：
 * 1. `executeWithRetry` 对**所有**请求在失败后立即轮换域名重试。写操作（发帖 / 回复 /
 *    收藏 / 签到）一旦遇到「已到达服务端但响应超时」，自动重试就会造成重复提交——
 *    这是不可逆的数据事故，比风控更严重；
 * 2. 失败重试**没有退避**，连续打多个域名，是所有行为里最像攻击的一种；
 * 3. NGA 的限流大多不是 HTTP 429，而是 200 + HTML 提示页 / JSON error 文案，
 *    只按状态码判定会完全漏掉风控。
 */

/** 风控冷却期默认时长（毫秒）。 */
export const DEFAULT_THROTTLE_COOLDOWN_MS: number = 60000
/** 首次重试的基础退避（毫秒）。 */
export const RETRY_BASE_DELAY_MS: number = 400
/** 单次重试退避上限（毫秒）。 */
export const RETRY_MAX_DELAY_MS: number = 3000

/**
 * 风控文案关键词（小写比较）。
 *
 * 只保留**强特征**词：'稍后再试''服务繁忙' 这类普通失败提示不在此列，
 * 否则一次正常报错就会把全站接口拖进 60 秒冷却，属于自伤。
 */
const THROTTLE_KEYWORDS: string[] = [
  '过于频繁',
  '太频繁',
  '刷新太快',
  '刷新过快',
  '访问太快',
  '操作太快',
  '频率限制',
  '频率过快',
  '请求频繁',
  'too many requests',
  'rate limit'
]

/**
 * 判断响应文本是否含风控信号。
 *
 * 覆盖两种真实形态：HTML 提示页（NGA 常见）与 JSON error 文案。
 * 调用方应在**状态码判定之后**再调用它，两者是「或」的关系。
 *
 * @param text - 原始响应文本（未解析的 body）
 * @returns true 表示命中风控文案
 */
export function looksLikeThrottle(text: string): boolean {
  if (text.length === 0) {
    return false
  }
  const lower: string = text.toLowerCase()
  for (let i: number = 0; i < THROTTLE_KEYWORDS.length; i++) {
    if (lower.indexOf(THROTTLE_KEYWORDS[i]) >= 0) {
      return true
    }
  }
  return false
}

/**
 * 确认**只读**的 `__lib/__act` 组合（白名单）。
 *
 * 用白名单而不是黑名单，是因为两种误判的代价完全不对称：
 * - 漏登记一个只读操作 → 弱网下少一次自动重试，用户重试即可；
 * - 漏登记一个写操作 → 超时后自动重复提交，产生不可逆的数据事故。
 *
 * 新增接口时**必须**在这里登记读操作，否则默认按写处理（不重试）。
 * 名单覆盖已知的全部 `ngaClient.postSigned` 调用点，改动调用点时应同步核对。
 */
const READ_ONLY_OPERATIONS: string[] = [
  // 发帖辅助：取分类（post 族里仅这个是读；recommend 是推荐/反对的状态变更，属于写）
  'post/titletype',
  /**
   * 发帖/回帖前的鉴权信息（auth / attach_url / 引用块 / 原标题）。
   *
   * 它是**读**：不产生任何服务端副作用，且幂等（同一 action+fid+tid+pid 恒返回同一份
   * 鉴权参数），因此重试安全。
   *
   * **必须登记**：写门禁以本白名单判定"是不是写操作"，漏登记会让降级态下的编辑器
   * （编辑、引用）在预取阶段就失败 —— 用户看得见编辑框、写得进正文，点提交才被拒。
   * 本名单同时服务于"是否允许自动重试"，两条语义在这里恰好一致。
   */
  'post/check',
  // 主题列表 / 搜索
  'subject/topped',
  'subject/hot',
  'subject/list',
  'subject/search',
  // 收藏夹目录（add/del 等同族操作是写）
  'topic_favor_v2/list_folder',
  // 版块收藏列表
  'forum_favor2/get',
  'favor/all',
  // 关注关系与动态
  'follow_v2/get_follow',
  'follow_v2/get_follow_by',
  'follow_v2/get_push_list',
  // 私信 / 通知
  'message/list',
  'message/detail',
  'notify/list',
  // 首页分类、版块搜索
  'home/category',
  'forum/search',
  // 会话校验
  'login/iflogin',
  // 用户资料 / 发帖回帖记录（成分分析用，只读）
  'ucp/get',
  'user/detail',
  'user/replys',
  'user/subjects',
  // 用户主题列表的 nuke 回退端点（只读）
  'load_topic/load_topic_by_uid'
]

/**
 * 判断一次签名接口调用是否为写操作（不可安全重试）。
 *
 * **默认按写处理**：不在 {@link READ_ONLY_OPERATIONS} 里的组合一律视为不可安全重试。
 * 这是「拿不准就不重试」的落地——不重试只是体验降级，重复提交是数据事故。
 *
 * @param lib - `__lib` 值
 * @param act - `__act` 值
 * @returns true 表示写操作，禁止自动重试
 */
export function isWritableOperation(lib: string, act: string): boolean {
  return READ_ONLY_OPERATIONS.indexOf(lib + '/' + act) < 0
}

/**
 * 计算第 n 次重试前的退避时长（指数增长，封顶）。
 *
 * @param attempt - 重试序号，从 1 开始
 * @returns 退避毫秒数
 */
export function retryDelayMs(attempt: number): number {
  if (attempt <= 0) {
    return 0
  }
  const delay: number = RETRY_BASE_DELAY_MS * Math.pow(2, attempt - 1)
  return Math.min(RETRY_MAX_DELAY_MS, Math.round(delay))
}

/**
 * 判断一个已解析的响应是否携带风控信号。
 *
 * 必须同时覆盖**两种响应形态**，否则主通道的风控会整条漏掉：
 * - 官方 app_api 业务失败：`{code, msg}`，`code = 15` 即频率限制
 *   （见 parser/AppSubjectListParser 的 extractSubjectListError 注释）；
 * - 网页版/HTML 错误页归一化：`{error: {0: 文案, 2: 错误码}}` 或 `{error_code}`。
 *
 * 判定**只看错误字段，绝不扫描整个响应体**：NGA 的论坛帖正文完全可能包含
 * 「过于频繁」「刷新太快」这类词（技术讨论、反馈帖）。对整段 200 响应做全文匹配，
 * 会让读到一个普通帖子就把**全站所有域名**拖进 60 秒冷却，正常浏览整体卡住——
 * 这个误伤路径比"漏判一次风控"严重得多。
 *
 * @param parsed - 已解析的响应对象
 * @returns true 表示命中风控
 */
export function hasThrottleSignal(parsed: Record<string, Object>): boolean {
  // 形态 A：官方 app_api 的 {code, msg}，15 即频率限制
  if (isCode15(parsed['code'])) {
    return true;
  }
  // 形态 B：顶层 error_code（HTML 错误页归一化，也可能是本模块自己产出的冷却响应）
  if (isCode15(parsed['error_code'])) {
    return true;
  }
  // 形态 C：{error: ...}
  const error: Object | undefined = parsed['error'];
  if (error === undefined || error === null) {
    return false;
  }
  if (typeof error === 'string') {
    return looksLikeThrottle(error as string);
  }
  if (typeof error !== 'object' || Array.isArray(error)) {
    return false;
  }
  const record: Record<string, Object> = error as Record<string, Object>;
  // 错误码优先：即便文案不含关键词，code=15 也一定是频率限制
  if (isCode15(record['2'])) {
    return true;
  }
  // 错误码为 0 表示"无错误"，此时文案不可信
  const code: Object | undefined = record['2'];
  if (code === 0 || code === '0') {
    return false;
  }
  const message: Object | undefined = record['0'];
  if (typeof message === 'string') {
    return looksLikeThrottle(message as string);
  }
  return false;
}

/**
 * 判断一个字段值是否表示「频率限制」错误码 15（兼容数字与字符串两种下发形态）。
 *
 * @param value - 原始字段值
 * @returns true 表示 code 为 15
 */
function isCode15(value: Object | undefined): boolean {
  if (typeof value === 'number') {
    return (value as number) === 15;
  }
  if (typeof value === 'string') {
    return (value as string) === '15';
  }
  return false;
}


