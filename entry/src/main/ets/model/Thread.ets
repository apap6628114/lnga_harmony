export interface ThreadPagination {
  page: number;
  totalPages: number;
  totalRows: number;
}

export interface ThreadInfo {
  tid: number;
  fid: number;
  subject: string;
  replies: number;
  authorid: number;
  author: string;
  /**
   * 主题作者（楼主）的稳定作者标识：普通帖为 uid 数字串，匿名帖为 `#anony_<32 位十六进制>`
   * 编码名（与楼层 `ThreadRowInfo.authorKey` 同源同义，见 html-thread 解析器）。
   * 身份比较只能用它——匿名帖的 `authorid` 是页内局部合成号，跨页不可比。
   * **判不出时为空串**（如匿名帖非首页、旧存档无该字段且无匿名名可依），调用方按"未知"处理。
   */
  authorKey: string;
  postdate: number;
  lastpost: number;
  lastposter: string;
  locked: boolean;
  recommend: number;
  digest: number;
  type: number;
  topic_misc: string;
}

export interface ThreadData {
  rowList: ThreadRowInfo[];
  threadInfo: ThreadInfo | null;
  __F: Record<string, string>;
  __ROWS: number;
  rowNum: number;
  pagination: ThreadPagination;
}

export interface ThreadRowInfo {
  tid: number;
  fid: number;
  pid: number;
  lou: number;
  authorid: number;
  author: string;
  /**
   * 稳定作者标识（跨页可比）：普通楼层为 uid 数字串，匿名楼层为 `#anony_` 编码名。
   * 由解析器给出（HTML 通道取 `__U` 的 username）；**判不出时为空串**（如匿名帖非首页
   * 页面完全不含匿名条目），调用方须按"未知"处理，不得用其他楼层的作者顶替。
   * 身份比较一律用它，详见 `PostInfo.authorKey`。
   */
  authorKey: string;
  subject: string;
  content: string;
  vote: string;
  postdate: string;
  /** 楼层发帖时间戳（UNIX 秒；postdate 为服务端格式化字符串）。 */
  postdatetimestamp: number;
  attachs: Attachment[];
  level: string;
  yz: string;
  js_escap_avatar: string;
  muteTime: string;
  aurvrc: number;
  signature: string;
  comments: ThreadRowInfo[];
  hotReplies: ThreadRowInfo[];
  from_client: string;
  from_client_model: string;
  isanonymous: boolean;
  alterinfo: string;
  score: number;
  score_2: number;
  isInBlackList: boolean;
  userNote: string;
  imageUrlList: string[];
  formattedHtmlData: string;
  postCount: string;
  reputation: number;
  memberGroup: string;
}

export interface Attachment {
  aid: string;
  attachurl: string;
  url_utf8_org_name: string;
  name: string;
  ext: string;
  type: string;
  size: number;
  thumb: number;
  dscp: string;
  subid: number;
}
