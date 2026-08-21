/**
 * thread.php 官方 APP 签名通道请求参数构建（纯函数，可独立测试）。
 *
 * 对应官方客户端 kt.c.V/W/S0（nga-hack 卡片 R2）的请求参数与签名参数规则：
 *  - 变体 A 普通列表：fid（"356"→"323"）/ stid 二选一 + page + order_by + recommend
 *  - 变体 C 主题搜索：key + table=7 + fid/stid 限定 + content + recommend
 *  - page > 100 需补 order_by=postdatedesc&nounion=1（否则服务端报 2048）
 *  - __output=14（卡片 R2 + 实测）
 *
 * signParams 规则（卡片 R2 + 实测）：有 key 用 key；否则有 fid 用映射后的 fid；
 * stid 场景（fid 置空）为空串——与请求参数「stid 优先」语义严格一致，
 * 避免 fid+stid 同传时签名与请求参数不一致导致 code=5 签名错误。
 *
 * 排序参数实测结论（nga-hack 探测，fid=7）：recommend=1 时额外传
 * order_by/user 不影响结果（三种变体首条一致），故 recommend 分支只发
 * recommend；order_by 仅用于独立排序（默认 lastpostdesc / postdatedesc）。
 *
 * 纯函数模块，不依赖 AppStore / 网络 / ForumApi 运行时依赖，可直接被
 * Hypium Local Test 覆盖。
 */

import type { TopicListParams } from '../../service/api/ForumApi'

/**
 * 官方 APP 的 fid 归一化（对齐官方客户端 kt.c.e0：`"356"` 被映射为 `"323"`）。
 *
 * @param fid - 页面层 fid
 * @returns 官方接口使用的 fid
 */
export function normalizeAppFid(fid: string): string {
  return fid === '356' ? '323' : fid;
}

/**
 * 构建 thread.php 官方 APP 签名通道的请求参数（POST form body）。
 *
 * @param params - 页面层主题列表参数
 * @returns 官方接口请求参数（进 POST body）
 */
export function buildAppThreadQuery(params: TopicListParams): Record<string, string> {
  const query: Record<string, string> = {
    'page': params.page || '1',
  };
  const fid: string = params.fid && params.fid !== '-1' ? normalizeAppFid(params.fid) : '';
  if (params.key) {
    // 变体 C：主题搜索
    query['key'] = params.key;
    query['table'] = '7';
    if (params.stid) query['stid'] = params.stid;
    else if (fid) query['fid'] = fid;
    if (params.content) query['content'] = params.content;
    if (params.recommend) query['recommend'] = params.recommend;
  } else {
    // 变体 A：普通列表（fid 优先 stid 二选一）
    if (params.stid) query['stid'] = params.stid;
    else if (fid) query['fid'] = fid;
    if (params.recommend) {
      // 实测：recommend=1 时服务端以 recommend 为准，order_by/user 不影响结果
      query['recommend'] = params.recommend;
    } else if (params.orderBy) {
      query['order_by'] = params.orderBy;
    }
  }
  const page: number = Number(params.page || '1') || 1;
  if (page > 100) {
    // 超过 100 页需 order_by=postdatedesc&nounion=1，否则服务端报 2048（卡片 R2）
    query['nounion'] = '1';
    if (!query['order_by']) {
      query['order_by'] = 'postdatedesc';
    }
  }
  return query;
}

/**
 * 计算官方 thread.php 通道的签名参数值（addSignParams）。
 *
 * 规则（卡片 R2 + 实测）：搜索用 key；普通列表用 fid（映射后）；
 * **stid 场景显式返回空串**（请求层 stid 优先时 fid 不参与，签名必须与
 * 请求参数一致，否则服务端返回 code=5 签名错误）。
 *
 * @param params - 页面层主题列表参数
 * @returns signParams 值
 */
export function buildAppSignParams(params: TopicListParams): string {
  if (params.key) {
    return params.key;
  }
  if (params.stid) {
    return '';
  }
  if (params.fid && params.fid !== '-1') {
    return normalizeAppFid(params.fid);
  }
  return '';
}
