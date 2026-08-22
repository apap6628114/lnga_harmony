/**
 * NGA 投票帖投票 API
 */

import { ngaClient } from '../NgaClient';
import { sessionRegistry } from '../../store/SessionRegistry';
import { VoteSubmitResult } from '../../model/NgaApiResults';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'VoteApi')

/**
 * 提交投票帖的投票。
 *
 * 官方 APP 接口为 `app_api.php?__lib=subject&__act=vote`，表单传入 tid、
 * voteid（逗号分隔选项 ID）和 raw=3，签名业务参数为 tid+voteid。
 * 成功时 msg 为服务端提示文本，失败时 code/msg 返回业务错误。
 *
 * @param token 会话令牌
 * @param tid 主题 ID
 * @param voteIds 选中的选项 ID 列表
 * @returns 提交结果
 */
export async function submitPollVote(token: string, tid: number, voteIds: string[]): Promise<VoteSubmitResult> {
  const result = new VoteSubmitResult();
  const session = sessionRegistry.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  if (voteIds.length === 0) {
    result.error = '请先选择投票选项';
    return result;
  }
  try {
    let ids: string = '';
    for (let i: number = 0; i < voteIds.length; i++) {
      if (i > 0) {
        ids += ','
      }
      ids += voteIds[i]
    }
    const params: Record<string, string> = {
      'raw': '3',
      'tid': String(tid),
      'voteid': ids,
    };
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/app_api.php', 'subject', 'vote', params,
      { uid: session.uid, cid: session.cid }, `${tid}${ids}`, '12'
    ) as Record<string, Object>;
    const code: number = Number(raw['code'] ?? 0);
    if (code !== 0) {
      result.error = String(raw['msg'] ?? `错误码: ${code}`);
      return result;
    }
    result.message = String(raw['msg'] ?? '投票成功');
    result.ok = true;
  } catch (e) {
    logger.warn('投票失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '投票失败';
  }
  return result;
}
