export interface MessageListInfo {
  rowsPerPage: number;
  nextPage: number;
  currentPage: number;
  messageEntryList: MessageThreadInfo[];
}

export interface MessageThreadInfo {
  mid: number;
  subject: string;
  time: string;
  lasttime: string;
  posts: number;
  from_username: string;
  last_from_username: string;
}

export interface MessageDetailInfo {
  nextPage: number;
  currentPage: number;
  alluser: string;
  title: string;
  messageEntryList: MessageArticle[];
}

export interface MessageArticle {
  /** 消息 ID（官方接口唯一标识，列表 key 用；网页版无此字段时为空）。 */
  id: string;
  /** 发送者 UID（官方接口 user.uid；0 为系统消息；网页版无此字段时为空）。 */
  uid: string;
  subject: string;
  time: string;
  content: string;
  from: string;
  lou: number;
  js_escap_avatar: string;
  author: string;
  yz: string;
  mute_time: string;
  signature: string;
  formated_html_data: string;
}
