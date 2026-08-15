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
  subject: string;
  content: string;
  vote: string;
  postdate: string;
  /** 楼层发帖时间戳（UNIX 秒，JSON/HTML 双通道均有；postdate 为服务端格式化字符串） */
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
