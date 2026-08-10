/**
 * NGA 投票帖数据模型。
 *
 * JSON API 的 vote 字段为 `~` 分隔的键值对字符串（官方 __NUKE.scEn/scDe 编码），
 * 经 VoteParser 解码为本模型。type 区分：0=投票 1=投注 2=评分 3=评分单条 4=问答。
 */

/**
 * 单个投票选项。
 */
export class VoteOption {
  /** 选项 ID（数字字符串，服务端投票提交参数值） */
  id: string = '';
  /** 选项标题 */
  title: string = '';
  /** 票数 */
  voteNum: number = 0;
  /** 投注量（投注帖用，投票帖为 0） */
  scoNum: number = 0;
}

/**
 * 解码后的投票信息。
 */
export class VoteInfo {
  /** 原始 vote 字符串 */
  raw: string = '';
  /** 投票类型：0=投票 1=投注 2=评分 3=评分单条 4=问答 */
  type: number = 0;
  /** 额外选项 bit：&1 提交后可查看结果，&2 结束后可查看结果 */
  opt: number = 0;
  /** 每人最多可选数（0=不限，官方 UI 按 1 处理） */
  maxSelect: number = 1;
  /** 投注/评分最小值 */
  min: number = 0;
  /** 投注/评分最大值 */
  max: number = 0;
  /** 结束时间戳（0=不结束） */
  end: number = 0;
  /** 投票声望限制说明 */
  priv: string = '';
  /** 投注结算选项（投注帖用） */
  done: string = '';
  /** 参与投票总人数 */
  userSum: number = 0;
  /** 总票数 */
  voteSum: number = 0;
  /** 总投注量 */
  scoSum: number = 0;
  /** 选项列表 */
  options: VoteOption[] = [];
}
