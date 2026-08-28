export interface User {
  userId: string;
  nickName: string;
  cid: string;
  avatarUrl: string;
}

/**
 * 用户搜索（nuke.php ucp get，按 uid 或用户名）返回的用户条目。
 */
export interface SearchUserItem {
  /** 用户 ID。 */
  uid: string;
  /** 用户名。 */
  userName: string;
  /** 头像地址（可为空，由 Avatar 组件兜底）。 */
  avatarUrl: string;
}

export class ProfileData {
  uid: string = '';
  userName: string = '';
  avatarUrl: string = '';
  group: string = '';
  title: string = '';
  honor: string = '';
  yz: number = 0;
  money: string = '';
  /** 接口冗余字段：实测与 rvrc 返回恒等值，UI 统一用 rvrc 展示威望（保留以对齐接口）。 */
  fame: string = '';
  rvrc: string = '';
  posts: string = '';
  /** 获赞数量（ucp.get 返回 `count_like`，官方口径为本年度所有帖子累计获赞数）。 */
  likeCount: string = '';
  regdate: string = '';
  sign: string = '';
  ipLoc: string = '';
  medal: string = '';
  muteTime: string = '';
  /** 我关注的人数（ucp.get 返回 `follow_num`）。 */
  followNum: string = '';
  /** 关注我的人数（ucp.get 返回 `follow_by_num`）。 */
  followByNum: string = '';
  /** 当前登录用户是否已关注该用户（ucp.get 返回 `follow: 1` 已关注 / `follow: 0` 未关注；抓自己时该字段缺席）。 */
  follow: boolean = false;
  adminForums: AdminForumsData[] = [];
  reputationEntryList: ReputationData[] = [];
}

export class AdminForumsData {
  fid: string = '';
  forumName: string = '';
}

/**
 * 多版面声望条目（ucp.get 的 `reputation` 字段，APP 签名通道 __output=12）。
 *
 * 官方语义（对齐网页端 js_ucp.js 渲染）：reputation 表示「论坛/某版面/某用户
 * 对目标用户的关系」，每个条目是 [名称, 数值, 描述] 三元组，如
 * ["N币", 181, "用于N币商店兑换,作货币使用"]。
 * 注意：这不是「威望历史记录」——NGA 无威望增删历史接口，历史各字段
 * （主题/内容/作者/时间）在真实数据中不存在。
 */
export class ReputationData {
  /** 声望名称（如「N币」）。 */
  name: string = '';
  /** 数值字符串（如 "181"）。 */
  value: string = '';
  /** 描述（如「用于N币商店兑换,作货币使用」）。 */
  desc: string = '';
  /** 数值形态（Number(value)；解析时已防 NaN，当前 UI 未消费，保留对齐官方三元组）。 */
  reputation: number = 0;
}
