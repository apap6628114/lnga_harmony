/**
 * 跟踪帖子更新的状态查询 API。
 *
 * 通道：`read.php` App 签名 POST + `__output=8`（GB18030 解码，见
 * `NgaClient.postSignedPathGb`）。选它而不是帖子详情的 `__output=17` HTML 通道，
 * 是因为单帖一次检查只需约 20KB 响应（HTML 通道实测 64KB），且 `__T` 直接给出
 * `replies`（总回复数）、`lastpost`（最后回复时间）、`subject`、`locked`，
 * 无需走 HTML 降级解析（省掉一次 taskpool 解析）。
 *
 * 三态结果见 {@link ThreadTrackStatus}：成功 / 失效（停止跟踪）/ 失败（下轮重试）。
 */

import { ngaClient, Cookies } from '../NgaClient'
import { appStore } from '../../store/AppStore'
import { parseThreadTrackStatus } from '../../parser/ThreadStatusParser'
import { ThreadTrackStatus } from '../../model/TrackedThread'
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadTrackApi')

/**
 * 查询单个帖子的最新状态。
 *
 * @param token - 当前应用会话令牌
 * @param tid - NGA 主题 ID
 * @returns 状态结果；未登录、请求失败或响应异常时 ok=false 且 invalid=false（保留跟踪）
 */
export async function fetchThreadTrackStatus(token: string, tid: string): Promise<ThreadTrackStatus> {
  const status: ThreadTrackStatus = new ThreadTrackStatus()
  const session = appStore.getSession(token)
  if (!session) {
    status.reason = '未登录'
    return status
  }
  if (tid.length === 0) {
    status.reason = '缺少帖子标识'
    return status
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = {
      'tid': tid,
      'pid': '',
      'topid': '',
      'authorid': '',
      'opt': '',
      'page': '1',
      '__localres': '1',
    }
    const raw: object = await ngaClient.postSignedPathGb('/read.php', params, cookies, '', '8')
    return parseThreadTrackStatus(raw)
  } catch (e) {
    // 用户可见文案固定化：原始异常（如 `Failed to connect ... code 2300007`）只进日志，
    // 否则对话框状态卡会直出技术文本
    status.reason = '检查失败，请稍后重试'
    logger.warn('检查帖子更新失败 tid=%{public}s: %{public}s', tid, formatError(e))
    return status
  }
}
