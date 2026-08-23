/**
 * NGA 用户资料「多版面声望」解析。
 *
 * ucp/get（官方 APP 签名通道，__output=12）的 reputation 字段表示「论坛/某
 * 版面/某用户对目标用户的关系」，条目为 [名称, 数值, 描述] 三元组，响应形态：
 *
 *   "reputation": [["N币", 181, "用于N币商店兑换,作货币使用"], ...]
 *
 * 官方网页端 js_ucp.js 的渲染口径一致：威望 = fame/10，随后逐条显示
 * 名称 = 数值（描述为悬浮提示）。
 *
 * 注意：NGA 不存在「威望历史记录」（主题/内容/作者/时间戳）数据。早期实现按
 * 7 元素数组错位解析，导致数值字段拿到描述字符串（Number 结果 NaN），主页
 * 显示「NaN 来自: 」。此处按官方三元组口径解析，杜绝该问题。
 *
 * 仅支持 APP 签名通道（__output=12）的数组形态；网页接口（lite=js /
 * __output=8）的对象形态（{声望id: {0: 名称, 1: 数值, 2: 描述}}）**不支持**
 * ——产品决策：鸿蒙端用户数据统一走官方 APP 签名通道，不再兼容网页接口形态。
 */

import { ReputationData } from '../model/User';

/**
 * 解析 ucp/get 用户对象中的 reputation 字段（APP 接口数组形态）。
 *
 * @param reputation - 用户对象的 reputation 字段值（缺失/非对象时返回空列表）
 * @returns 多版面声望条目列表
 */
export function parseReputationList(reputation: Object | undefined): ReputationData[] {
  const list: ReputationData[] = [];
  if (reputation === undefined || reputation === null || typeof reputation !== 'object') {
    return list;
  }
  const repObj = reputation as Record<string, Object>;
  const repKeys = Object.keys(repObj);
  for (let i = 0; i < repKeys.length; i++) {
    const entry: Object | undefined = repObj[repKeys[i]];
    if (Array.isArray(entry)) {
      /* APP 接口形态：[名称, 数值, 描述] */
      const arr = entry as Object[];
      const item = new ReputationData();
      item.name = String(arr[0] ?? '');
      item.value = String(arr[1] ?? '');
      item.desc = String(arr[2] ?? '');
      const numericValue: number = Number(arr[1] ?? 0);
      item.reputation = isNaN(numericValue) ? 0 : numericValue;
      list.push(item);
    }
  }
  return list;
}
