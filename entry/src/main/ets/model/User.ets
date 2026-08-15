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
  fame: string = '';
  rvrc: string = '';
  posts: string = '';
  regdate: string = '';
  sign: string = '';
  ipLoc: string = '';
  medal: string = '';
  muteTime: string = '';
  followByNum: string = '';
  /** 当前登录用户是否已关注该用户（ucp.get 条件返回 `follow: 1`，未关注时字段缺席）。 */
  follow: boolean = false;
  adminForums: AdminForumsData[] = [];
  reputationEntryList: ReputationData[] = [];
}

export class AdminForumsData {
  fid: string = '';
  forumName: string = '';
}

export class ReputationData {
  name: string = '';
  value: string = '';
  desc: string = '';
  reputation: number = 0;
  topicSubject: string = '';
  postContent: string = '';
  author: string = '';
  time: number = 0;
}
