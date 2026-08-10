/**
 * NGA 投票字段解析器。
 *
 * 输入为 JSON API 楼级 `vote` 字段 / `__T.post_misc_var.vote` 的字符串，
 * 格式为 `键~值~键~值~...`（官方 `__NUKE.scEn/scDe` 编码）：
 * - `<选项ID>~<选项标题>`：数字键为投票选项
 * - `_<选项ID>~<票数>,<投注量>,<总人数>`：选项统计（总人数只出现在首个选项，取最大）
 * - `max_select~<n>` 每人最多可选；`type~<n>` 类型；`end~<ts>` 结束时间戳；
 *   `opt~<bit>` 结果查看限制；`min/max` 投注/评分边界；`priv` 声望限制；`done` 投注结算
 *
 * 语义与官方 js_read.js `commonui.voteFormat` 对齐：选项票数为 `_<id>` 首段，
 * 总人数取所有选项第三段最大值，总票数为各选项票数之和。
 */

import { VoteInfo, VoteOption } from '../model/Vote';

/**
 * 解码 vote 字符串为结构化投票信息。
 *
 * @param raw vote 字符串（可为空）
 * @returns 解码结果；无选项或格式非法时返回 null
 */
export function parseVote(raw: string): VoteInfo | null {
  if (!raw || raw.length === 0) {
    return null;
  }
  const parts: string[] = raw.split('~');
  if (parts.length < 2) {
    return null;
  }
  const info: VoteInfo = new VoteInfo();
  info.raw = raw;
  let userSum: number = 0;
  let voteSum: number = 0;
  let scoSum: number = 0;
  const options: VoteOption[] = [];
  for (let i: number = 0; i + 1 < parts.length; i += 2) {
    const key: string = parts[i];
    const value: string = parts[i + 1];
    const numKey: number = Number(key);
    if (numKey > 0) {
      const opt: VoteOption = new VoteOption();
      opt.id = key;
      opt.title = value;
      const statKey: string = '_' + key;
      for (let j: number = 0; j + 1 < parts.length; j += 2) {
        if (parts[j] === statKey) {
          const nums: string[] = parts[j + 1].split(',');
          opt.voteNum = parseInt(nums[0], 10) || 0;
          opt.scoNum = parseInt(nums[1], 10) || 0;
          const u: number = parseInt(nums[2], 10) || 0;
          if (u > userSum) {
            userSum = u;
          }
          break;
        }
      }
      voteSum += opt.voteNum;
      scoSum += opt.scoNum;
      options.push(opt);
    } else if (key === 'max_select') {
      const v: number = parseInt(value, 10) || 0;
      info.maxSelect = v > 0 ? v : 1;
    } else if (key === 'type') {
      info.type = parseInt(value, 10) || 0;
    } else if (key === 'opt') {
      info.opt = parseInt(value, 10) || 0;
    } else if (key === 'min') {
      info.min = parseInt(value, 10) || 0;
    } else if (key === 'max') {
      info.max = parseInt(value, 10) || 0;
    } else if (key === 'end') {
      info.end = parseInt(value, 10) || 0;
    } else if (key === 'priv') {
      info.priv = value;
    } else if (key === 'done') {
      info.done = value;
    }
  }
  if (options.length === 0) {
    return null;
  }
  info.options = options;
  info.userSum = userSum;
  info.voteSum = voteSum;
  info.scoSum = scoSum;
  return info;
}

/**
 * 单项占比显示值：((值/总和*1000)|0)/10 一位小数截断，与官方 votePercentString 一致。
 *
 * @param value 单项指标值（票数或投注量）
 * @param sum 组内指标总和
 * @returns 百分比数值（如 81.3 表示 81.3%）；sum<=0 时返回 0
 */
export function votePercent(value: number, sum: number): number {
  if (sum <= 0) {
    return 0;
  }
  return Math.floor((value / sum) * 1000) / 10;
}

/**
 * 进度条宽度百分比：组内最高项归一化到 75% 宽度（官方 voteFormatGroup 的 voteMul 语义），
 * 最高项占比 >=75% 时不缩放。
 *
 * @param value 单项指标值
 * @param sum 组内指标总和
 * @param most 组内最高指标值
 * @returns 宽度百分比（0-100）
 */
export function barPercent(value: number, sum: number, most: number): number {
  if (sum <= 0) {
    return 0;
  }
  let mul: number = 1;
  if (most > 0) {
    const mostRate: number = most / sum;
    if (mostRate < 0.75) {
      mul = 0.75 / mostRate;
    }
  }
  let p: number = votePercent(value, sum) * mul;
  if (p > 100) {
    p = 100;
  }
  return p;
}

/**
 * type 2 评分单项均分：((投注量/票数*100)|0)/100 两位小数截断，官方 voteScore 的 scc 语义。
 *
 * @param scoNum 投注量（评分帖中为总分）
 * @param voteNum 参与人数
 * @returns 均分；voteNum<=0 时返回 0
 */
export function scoreValue(scoNum: number, voteNum: number): number {
  if (voteNum <= 0) {
    return 0;
  }
  return Math.floor((scoNum / voteNum) * 100) / 100;
}
