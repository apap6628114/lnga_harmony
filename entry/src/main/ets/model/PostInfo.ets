/**
 * 帖子详情页的主帖与评论数据模型。
 * PostInfo 由 ThreadParser 解析后填充，PostAttachInfo 描述帖子内联附件。
 */

/**
 * 帖子附件信息（图片/文件等内联附件）。
 */
export class PostAttachInfo {
  aid: string = '';
  attachurl: string = '';
  url_utf8_org_name: string = '';
  name: string = '';
  ext: string = '';
  type: string = '';
  size: number = 0;
  thumb: number = 0;
  thumbUrl: string = '';
  dscp: string = '';
  subid: number = 0;
}

/**
 * 单条帖子（主帖或回复/评论/热点回复，结构同构可递归）。
 */
export class PostInfo {
  tid: number = 0;
  pid: number = 0;
  /**
   * 本地渲染版本号（非服务端字段）：楼层内容更新时递增。
   * 驱动 LazyForEach 键值变化以重建该楼层——LazyForEach 的 onDataChange
   * 仅在键值变化时刷新组件，而键值含 pid 不含内容，故内容变化必须借 uiRev 表达。
   */
  uiRev: number = 0;
  lou: number = 0;
  authorid: number = 0;
  author: string = '';
  /**
   * 稳定作者标识（非服务端新字段，由 `ThreadRowInfo.authorKey` 透传）：
   * 普通楼层为 uid 数字串，匿名楼层为 `#anony_<32 位十六进制>` 编码名。
   *
   * 为什么不能直接用 `authorid` 判身份：NGA 匿名楼层的 uid 是**页内局部合成号**
   * （`-1`、`-2`…，每页按楼层出现顺序重新分配，同一匿名用户在第二页可能是另一个
   * 负数，主题作者的 tAid 又是第三个数），拿它跨页比较「是不是楼主」必然错位——
   * 楼主的后续匿名回复认不出，别的匿名用户还可能撞上同一个局部号被误标。
   * 只有 `#anony_` 编码名在同一帖子内稳定，故身份比较（楼主标记、只看楼主）
   * 一律用本字段，`authorid` 只保留给引用协议、资料卡、黑名单等 uid 语义场景。
   */
  authorKey: string = '';
  subject: string = '';
  content: string = '';
  /** 投票帖原始 vote 字符串（`~` 分隔键值对，仅主楼有值），经 VoteParser 解码渲染 */
  vote: string = '';
  postdate: string = '';
  /** 发帖时间戳（UNIX 秒），用于本地格式化；postdate 仅作服务端字符串兜底 */
  postdatetimestamp: number = 0;
  level: string = '';
  yz: string = '';
  avatar: string = '';
  signature: string = '';
  attachs: PostAttachInfo[] = [];
  comments: PostInfo[] = [];
  /** 热点回复（热门回复），值为完整楼层结构，由楼主楼层 hotreply 字段递归解析 */
  hotReplies: PostInfo[] = [];
  fromClient: string = '';
  from_client_model: string = '';
  isanonymous: boolean = false;
  alterinfo: string = '';
  score: number = 0;
  score_2: number = 0;
  isInBlackList: boolean = false;
  userNote: string = '';
  isMuted: boolean = false;
  reputation: number = 0;
  memberGroup: string = '';
  postCount: string = '';
  muteTime: string = '';
}
