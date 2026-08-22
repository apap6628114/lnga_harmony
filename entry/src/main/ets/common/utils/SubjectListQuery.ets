/**
 * subject 系官方 APP 签名接口请求参数构建（纯函数，可独立测试）。
 *
 * 对应官方客户端 kt.c.V/W（subject/list 普通列表）与 kt.c.S0（subject/search
 * 主题搜索）的请求参数与签名参数规则（nga-hack pswitch_522/pswitch_50e 映射）：
 *  - 变体 list：fid（"356"→"323"）/ stid 二选一 + page + order_by + recommend
 *  - 变体 search：key + table=7 + fid/stid 限定 + content + recommend
 *  - page > 100 需补 order_by=postdatedesc&nounion=1（否则服务端报 2048）
 *  - __output=12（buildNew 默认）
 *
 * signParams 规则（实测确认）：
 *  - 搜索用 key（实测：传 fid 返回 code=5 签名错误）
 *  - 普通列表用 fid（映射后；实测：空串返回 code=5 签名错误）
 *  - stid 场景（fid 置空）为空串（实测：传 stid 返回 code=5 签名错误）
 *
 * 排序参数实测结论（nga-hack 探测，fid=7）：recommend=1 时额外传
 * order_by/user 不影响结果，故 recommend 分支只发 recommend；
 * order_by 仅用于独立排序（默认 lastpostdesc / postdatedesc）。
 *
 * 与官方实现的形态差异（等价性有实测背书）：官方 kt.c.W/S0 恒发 fid/stid
 * （空串也发）并恒发 order_by（默认 postdatedesc）与 recommend（默认 0）；
 * 鸿蒙端省略缺省参数（旧 thread.php 通道的 AppTopicListQuery 采用同一
 * 省略策略且已实测上线）。另官方在 recommend=true 且 stid 非空时 fid+stid
 * 同发（signParams=[fid]），鸿蒙端 stid 场景只发 stid（signParams=''，
 * 实测空串签名有效），该边缘组合风险低。
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
export function normalizeSubjectFid(fid: string): string {
  return fid === '356' ? '323' : fid;
}

/**
 * 构建 subject 系官方 APP 签名接口的请求参数（POST form body）。
 *
 * @param params - 页面层主题列表参数
 * @returns 官方接口请求参数
 */
export function buildSubjectQuery(params: TopicListParams): Record<string, string> {
  const query: Record<string, string> = {
    'page': params.page || '1',
  };
  const fid: string = params.fid && params.fid !== '-1' ? normalizeSubjectFid(params.fid) : '';
  if (params.key) {
    // 变体 search：主题搜索
    query['key'] = params.key;
    query['table'] = '7';
    if (params.stid) query['stid'] = params.stid;
    else if (fid) query['fid'] = fid;
    if (params.content) query['content'] = params.content;
    if (params.recommend) query['recommend'] = params.recommend;
  } else {
    // 变体 list：普通列表（fid 优先 stid 二选一）
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
    // 超过 100 页需 order_by=postdatedesc&nounion=1，否则服务端报 2048
    query['nounion'] = '1';
    if (!query['order_by']) {
      query['order_by'] = 'postdatedesc';
    }
  }
  return query;
}

/**
 * 计算 subject 系官方接口的签名参数值（addSignParams）。
 *
 * 规则（实测确认）：搜索用 key；普通列表用 fid（映射后）；
 * **stid 场景显式返回空串**（请求层 stid 优先时 fid 不参与，签名必须与
 * 请求参数一致，否则服务端返回 code=5 签名错误）。
 *
 * @param params - 页面层主题列表参数
 * @returns signParams 值
 */
export function buildSubjectSignParams(params: TopicListParams): string {
  if (params.key) {
    return params.key;
  }
  if (params.stid) {
    return '';
  }
  if (params.fid && params.fid !== '-1') {
    return normalizeSubjectFid(params.fid);
  }
  return '';
}

/**
 * 计算子版块订阅操作的 type 参数（官方 subject/subscription）。
 *
 * type=1 订阅（子版块主题混合进父版块列表）、type=2 取消订阅（服务端排除）。
 *
 * @param show - 是否在父版块中显示（true=订阅，false=取消订阅）
 * @returns '1' 或 '2'
 */
export function buildSubscriptionType(show: boolean): string {
  return show ? '1' : '2';
}

/**
 * 构建子版块订阅操作的业务参数（官方 subject/subscription 的 POST body）。
 *
 * 参数与官方 T0 方法（NetRequestWrapper.smali）逐字段一致：
 * ufid=父版块 fid、fid=子版块 fid、type=1/2、sub_type=subForum.sub_type、
 * tid=subForum.tid（635 版镜像 id）。
 *
 * @param parentFid - 父版块 fid
 * @param subFid - 子版块 fid
 * @param subType - 子版块 sub_type（subForum 元素值）
 * @param tid - 子版块 tid（subForum 元素值，635 版镜像 id）
 * @param show - 是否在父版块中显示（true=订阅，false=取消订阅）
 * @returns 订阅操作业务参数
 */
export function buildSubscriptionFields(parentFid: number, subFid: number,
  subType: number, tid: string, show: boolean): Record<string, string> {
  const ufid: string = String(parentFid);
  const fid: string = String(subFid);
  const fields: Record<string, string> = {
    'ufid': ufid,
    'fid': fid,
    'type': buildSubscriptionType(show),
    'sub_type': String(subType),
    'tid': tid,
  };
  return fields;
}

/**
 * 计算子版块订阅操作的签名参数值（addSignParams）。
 *
 * 规则（T0 smali + 实测确认）：ufid+fid+type 直接拼接（如订阅 fid=124 的
 * 子版块到 fid=7 父版块 → "71241"）；错误拼接返回 code=5 签名错误。
 *
 * @param parentFid - 父版块 fid
 * @param subFid - 子版块 fid
 * @param show - 是否在父版块中显示（true=订阅，false=取消订阅）
 * @returns signParams 值
 */
export function buildSubscriptionSignParams(parentFid: number, subFid: number,
  show: boolean): string {
  return String(parentFid) + String(subFid) + buildSubscriptionType(show);
}
