/**
 * NGA 投票帖投票 API
 */

import { ngaClient } from '../NgaClient';
import { sessionRegistry } from '../../store/SessionRegistry';
import { parseNgaError } from '../../parser/ErrorParser';
import { VoteSubmitResult } from '../../model/NgaApiResults';

/**
 * 提交投票帖的投票。
 *
 * 官方实现（js_read.js commonui.vote.submit → __API.vote）：
 * POST /nuke.php?__lib=vote&__act=vote&tid=<tid>&voteid=<逗号分隔选项ID>&raw=3
 * 成功时 data[0] 为服务端提示文本（如"投票成功"），失败时返回错误信息。
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
    const fields: Record<string, string> = {
      '__lib': 'vote',
      '__act': 'vote',
      'raw': '3',
      '__output': '8',
      'tid': String(tid),
      'voteid': ids,
    };
    const raw = await ngaClient.post('/nuke.php', fields, { uid: session.uid, cid: session.cid });
    const err = parseNgaError(raw);
    if (err) {
      result.error = err;
      return result;
    }
    const rawObj = raw as Record<string, Object>;
    const dataObj = rawObj['data'] as Record<string, Object>;
    result.message = String(dataObj?.['0'] ?? '投票成功');
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '投票失败';
  }
  return result;
}
